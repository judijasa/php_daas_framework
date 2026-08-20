#!/usr/bin/env bash
# Generic production provisioning (framework mechanism).
#
# Runs as root on the remote via `deploy --init`, from the deployed repo
# root (the repo directory already exists — created by the deploy swap).
# Parameterized entirely by the committed etc/deploy.conf; the consumer owns
# the values, the framework owns the mechanism. Idempotent.
#
# What this covers:
#   1. Assert the app user (PROD_USER) exists — creation and SSH access are
#      documented pre-deploy prerequisites (assert-only by design).
#   2. Create the permanent dirs (log dir, DB base dir, deploy parent),
#      owned by PROD_USER.
#   3. Initialize the MariaDB instance datadir if missing/empty.
#   4. Write the per-project server defaults file and install the
#      mariadb@.service systemd template unit.
#   5. Preflight conflict detection, then enable + start the instance
#      (exactly once; idempotent, survives reboots).
#
# The instance identity is derived by convention from one base dir — the
# same shape as the dev sandbox's $PWD/var/mariadb:
#   datadir  = $DEPLOY_DB_BASE/data
#   socket   = $DEPLOY_DB_BASE/mysql.sock
#   pid-file = $DEPLOY_DB_BASE/mysql.pid
# The per-project defaults file (/etc/<instance>/my.cnf) shields the daemon
# from the global /etc/mysql/ includes, which would inject the distro
# socket/port/pid paths and collide with other instances on the same host.
# Socket-only by default (skip-networking, like dev); set DEPLOY_DB_PORT to
# enable TCP on a per-project port instead.
#
# Conflict diagnostics stay generic on purpose (no pid/owner disclosure):
# provisioning logs may be read beyond the operator.
#
# Consumer-specific extras (e.g. Apache/www-data traversal, app-specific
# state) belong in DEPLOY_INIT_CMD, which `deploy --init` runs after this
# script.
#
# Usage: provision.sh   (root; config from etc/deploy.conf)

set -euo pipefail

set -a
. ./etc/deploy.conf
set +a

# --- Instance identity: consumer data in, convention out ----------------
DB_BASE="${DEPLOY_DB_BASE:?DEPLOY_DB_BASE is required (see etc/deploy.conf.template)}"
DB_INSTANCE="${DEPLOY_DB_INSTANCE:-$(basename "$DEPLOY_TARGET_DIR")}"
DB_DATA_DIR="$DB_BASE/data"
DB_SOCKET="$DB_BASE/mysql.sock"
DB_PID_FILE="$DB_BASE/mysql.pid"
DB_ERROR_LOG="$DEPLOY_LOG_DIR/mariadb.log"
# Env overrides below exist for sandbox testing only; production always uses
# /etc/<instance> and /etc/systemd/system.
DB_CONF_DIR="${DEPLOY_DB_CONF_DIR:-/etc/$DB_INSTANCE}"
DB_CONF_FILE="$DB_CONF_DIR/my.cnf"
DB_SYSTEMD_DIR="${DEPLOY_SYSTEMD_DIR:-/etc/systemd/system}"
DB_UNIT_FILE="$DB_SYSTEMD_DIR/mariadb@.service"
DB_UNIT="mariadb@$DB_INSTANCE"

# Resolve the server binary once (Debian ships mariadbd with a mysqld
# symlink; other distros may ship mysqld only).
MARIADBD="$(command -v mariadbd || command -v mysqld || true)"
if [ -z "$MARIADBD" ]; then
    echo "ERROR: mariadbd/mysqld not found on this host (install MariaDB server)." >&2
    exit 1
fi
INSTALL_DB_BIN="$(command -v mariadb-install-db || true)"
if [ -z "$INSTALL_DB_BIN" ]; then
    echo "ERROR: mariadb-install-db not found on this host (install MariaDB server)." >&2
    exit 1
fi
PING_BIN="$(command -v mariadb-admin || command -v mysqladmin || true)"

# 1. Assert the provisioning system user exists (assert-only by decision;
#    ssh access to PROD_USER is a documented pre-deploy prerequisite).
echo "Asserting that system user '$PROD_USER' exists..."
if ! id -u "$PROD_USER" >/dev/null 2>&1; then
    echo "ERROR: System user '$PROD_USER' does not exist on this host." >&2
    echo "Please provision the user (and its ssh access) before running this deployment." >&2
    exit 1
fi

# 2. Create permanent system dirs owned by the app user, plus the deploy
#    parent dir. The /etc/<instance> config dir stays root-owned (the daemon
#    drops privileges itself via user= in the defaults file).
echo "Creating permanent system logging and storage directories..."
mkdir -p "$DEPLOY_LOG_DIR" "$DB_DATA_DIR" "$DB_CONF_DIR"
chown -R "$PROD_USER:$PROD_USER" "$DEPLOY_LOG_DIR" "$DB_BASE"
mkdir -p "$(dirname "$DEPLOY_TARGET_DIR")"
chown "$PROD_USER:$PROD_USER" "$(dirname "$DEPLOY_TARGET_DIR")"

# 3. Initialize the raw MariaDB instance structures (datadir owned by the
#    app user). No --auth-root-authentication-method flag here: prod uses
#    unix_socket auth, unlike the dev sandbox. The emptiness check (not just
#    existence) is deliberate: mkdir -p above creates the dir, so a bare
#    existence test would never trigger the init.
echo "Initializing raw MariaDB instance structures..."
if [ -z "$(ls -A "$DB_DATA_DIR" 2>/dev/null)" ]; then
    "$INSTALL_DB_BIN" --datadir="$DB_DATA_DIR" --user="$PROD_USER"
else
    echo "    MariaDB datadir already initialized. Skipping."
fi

# 4. Per-project defaults file: keeps this instance away from the global
#    /etc/mysql/ includes (they inject the distro socket/port/pid paths).
echo "Writing per-project MariaDB defaults file ($DB_CONF_FILE)..."
{
    echo "[mysqld]"
    echo "datadir   = $DB_DATA_DIR"
    echo "socket    = $DB_SOCKET"
    echo "pid-file  = $DB_PID_FILE"
    echo "log-error = $DB_ERROR_LOG"
    echo "user      = $PROD_USER"
    if [ -n "${DEPLOY_DB_PORT:-}" ]; then
        echo "port      = $DEPLOY_DB_PORT"
    else
        echo "skip-networking"
    fi
} > "$DB_CONF_FILE"
chmod 644 "$DB_CONF_FILE"

# 5. systemd template unit: one file, one unit instance per project; the
#    instance name selects the defaults file (/etc/<instance>/my.cnf).
echo "Installing systemd template unit ($DB_UNIT_FILE)..."
cat > "$DB_UNIT_FILE" <<EOF
[Unit]
Description=MariaDB instance %i
After=network.target

[Service]
ExecStart=$MARIADBD --defaults-file=/etc/%i/my.cnf
Restart=on-failure
RestartSec=3
LimitNOFILE=infinity

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload

# 6. Preflight + start (idempotent). Diagnostics are generic — never reveal
#    which pid/owner holds a taken path.
if systemctl is-active --quiet "$DB_UNIT" 2>/dev/null; then
    echo "    MariaDB unit $DB_UNIT already active. Skipping."
    echo "Provisioning complete."
    exit 0
fi

# Instance already running outside systemd (manual/legacy start): adopt it —
# enable the unit for boot durability without starting a second daemon.
if [ -S "$DB_SOCKET" ] && [ -f "$DB_PID_FILE" ] && kill -0 "$(cat "$DB_PID_FILE")" 2>/dev/null; then
    echo "    WARNING: instance already running outside systemd (socket $DB_SOCKET). Enabling unit for boot durability..."
    systemctl enable "$DB_UNIT"
    echo "Provisioning complete."
    exit 0
fi

# Stale pid-file from a previous crash (process no longer alive).
if [ -f "$DB_PID_FILE" ] && ! kill -0 "$(cat "$DB_PID_FILE")" 2>/dev/null; then
    echo "    WARNING: stale pid-file $DB_PID_FILE (process not alive). Removing."
    rm -f "$DB_PID_FILE"
fi

# Socket present but no server answering: stale leftover — remove. A live
# server on our socket is a conflict: refuse with a generic message.
if [ -S "$DB_SOCKET" ]; then
    if [ -n "$PING_BIN" ] && "$PING_BIN" --socket="$DB_SOCKET" ping >/dev/null 2>&1; then
        echo "ERROR: socket $DB_SOCKET already taken." >&2
        exit 1
    fi
    echo "    WARNING: stale socket $DB_SOCKET (no server answering). Removing."
    rm -f "$DB_SOCKET"
fi

# TCP port already in use (only relevant when networking is enabled).
if [ -n "${DEPLOY_DB_PORT:-}" ]; then
    if command -v ss >/dev/null 2>&1 && ss -tln | awk '{print $4}' | grep -q ":$DEPLOY_DB_PORT$"; then
        echo "ERROR: TCP port $DEPLOY_DB_PORT already taken." >&2
        exit 1
    fi
fi

# All clear: start the instance once via systemd (also survives reboots).
systemctl enable --now "$DB_UNIT"
echo "Provisioning complete."
