#!/usr/bin/env bash
# Generic production provisioning (framework mechanism).
#
# Runs as root on the remote via `deploy`, from the deployed repo
# root (the repo directory already exists — created by the deploy swap).
# Parameterized by the consumer's etc/deploy.conf — sourced as a plain
# file when present, otherwise the replayed deploy.conf environment supplies
# the values. The consumer owns the values,
# the framework owns the mechanism. Idempotent.
#
# The framework does NOT create databases or users: those are created by
# `ema create` at database-creation time (one instance per database), and
# the operator records the emitted connectivity in the consumer's manual
# reuter.ini (see doc/system/ema.md). This script asserts the app user,
# creates the permanent system dirs, and installs the framework-owned
# `mariadb@.service` template unit (the static unit ema asserts before
# provisioning any instance).
#
# What this covers:
#   1. Assert the app user (PROD_USER) exists — creation and SSH access are
#      documented pre-deploy prerequisites (assert-only by design).
#   2. Create the permanent system dirs (log dir, deploy parent),
#      owned by PROD_USER.
#   3. Install the framework-owned mariadb@.service template unit (idempotent;
#      canonical content, overwritten on drift).
#
# Consumer-specific extras (e.g. Apache/www-data traversal, app-specific
# state) belong in DEPLOY_INIT_CMD, which `deploy` runs after this
# script.
#
# Usage: pf-provision.sh   (root; config from etc/deploy.conf or the replayed env)

set -euo pipefail

# Values come from the replayed deploy.conf environment (see pf-deploy.sh);
# a consumer that commits a real etc/deploy.conf still overrides it.
if [[ -f ./etc/deploy.conf ]]; then
    set -a
    # shellcheck disable=SC1091
    . ./etc/deploy.conf
    set +a
fi

# Locate this package's root directory. $0 is vendor/bin/pf-provision.sh, a
# composer symlink into vendor/<vendor>/<pkg>/bin/pf-provision.sh; follow it
# one hop and keep the result logical (cd + pwd, no further resolution) so a
# path-repository consumer still resolves to the path the host holds.
_fw_pkg_root() {
    local self="$0" link
    if [[ -L "$self" ]]; then
        link="$(readlink "$self")"
        case "$link" in
            /*) self="$link" ;;
            *)  self="$(dirname "$self")/$link" ;;
        esac
    fi
    cd "$(dirname "$self")/.." && pwd
}

# 1. Assert the provisioning system user exists (assert-only by decision;
#    ssh access to PROD_USER is a documented pre-deploy prerequisite).
echo "Asserting that system user '$PROD_USER' exists..."
if ! id -u "$PROD_USER" >/dev/null 2>&1; then
    echo "ERROR: System user '$PROD_USER' does not exist on this host." >&2
    echo "Please provision the user (and its ssh access) before running this deployment." >&2
    exit 1
fi

# 2. Create permanent system dirs owned by the app user (every host), plus
#    the deploy parent dir.
echo "Creating permanent system logging and storage directories..."
mkdir -p "$DEPLOY_LOG_DIR"
chown -R "$PROD_USER:$PROD_USER" "$DEPLOY_LOG_DIR"
mkdir -p "$(dirname "$DEPLOY_TARGET_DIR")"
chown "$PROD_USER:$PROD_USER" "$(dirname "$DEPLOY_TARGET_DIR")"

# 3. Install the framework-owned mariadb@.service template unit (static file;
#    ema asserts its presence before provisioning any instance, so it must be
#    in place before the first `ema create`). Idempotent: copy only when it
#    differs, then daemon-reload.
echo "Installing the mariadb@.service template unit..."
unit_src="$(_fw_pkg_root)/etc/mariadb@.service"
unit_dst="/etc/systemd/system/mariadb@.service"
if [[ ! -f "$unit_src" ]]; then
    echo "ERROR: $unit_src not found in the framework package." >&2
    exit 1
fi
if [[ ! -f "$unit_dst" ]] || ! cmp -s "$unit_src" "$unit_dst"; then
    install -m 644 "$unit_src" "$unit_dst"
    echo "Installed $unit_dst."
fi
systemctl daemon-reload

echo "Provisioning complete."
