#!/usr/bin/env bash
# Create .env (git-ignored) with the machine configuration:
#   - REPO_PATH/REPO_LOG/REUTER_INI: runtime config consumed by phprun and
#     the framework's Database class;
#   - EMA_TARGET=sandbox: machine-mode signal for the ema CLI only;
#   - DBUSER: this machine's team member name, resolved from etc/team.ini
#     (the section whose entries include the local hostname; skipped with a
#     warning when no mapping exists). Needed for remote access to prod only.
# Also refreshes etc/reuter.ini [prod] connectivity from etc/machines.ini via
# gen-reuter (when available).
#
# The dev MariaDB instance is NOT initialized or started here: ema owns the
# per-instance sandbox lifecycle (`ema sandbox` / `ema start` / `ema stop`),
# so no MYSQL_* paths are written to .env anymore.
#
# Backend for the Makefile target _dev-init-local-env (make dev-init) in
# this repo and in consumer repos (shipped in the nix package, on PATH).
# Always regenerates the file: a stale .env would silently misconfigure
# phprun (it loads the repo-root .env from the CWD at runtime).
# Usage: init-local-env.sh [target-dir]   (defaults to $PWD)

set -euo pipefail

TARGET_DIR="${1:-$PWD}"
REPO_PATH="$(cd "$TARGET_DIR" && pwd)"
REPO_VAR="$REPO_PATH/var"
REPO_LOG="$REPO_VAR/log"

# Inject git-ignored private config (etc/machines.ini, etc/team.ini) from the
# private repository referenced by .private-source, when configured (no-op
# otherwise), so DBUSER resolution and gen-reuter see the private data.
if command -v fetch-private-data >/dev/null 2>&1; then
    ( cd "$REPO_PATH" && fetch-private-data )
elif [ -x "$REPO_PATH/bin/fetch-private-data" ]; then
    ( cd "$REPO_PATH" && "$REPO_PATH/bin/fetch-private-data" )
fi

{
    printf 'export REPO_PATH=%s\n' "$REPO_PATH"
    printf 'export REPO_LOG=%s\n' "$REPO_LOG"
    printf 'export REUTER_INI=%s/var/reuter.local.ini\n' "$REPO_PATH"
    printf 'export EMA_TARGET=sandbox\n'

    if [ ! -f "$REPO_PATH/etc/team.ini" ]; then
        echo "WARNING: $REPO_PATH/etc/team.ini not found. Skipping DBUSER (needed for remote access only)." >&2
    else
        _dbuser=$(awk -F= -v h="$(hostname)" '
            /^[[:space:]]*[;#]/ { next }
            /^[[:space:]]*$/ { next }
            /^[[:space:]]*\[/ { gsub(/^[[:space:]]*\[|][[:space:]]*$/, "", $0); sec = $0; next }
            {
                key = $1
                gsub(/^[[:space:]]+|[[:space:]]+$/, "", key)
                if (key != "subject" && key == h) { print sec; exit }
            }
        ' "$REPO_PATH/etc/team.ini")
        if [ -z "$_dbuser" ]; then
            echo "WARNING: hostname '$(hostname)' not found in $REPO_PATH/etc/team.ini. Skipping DBUSER (needed for remote access only)." >&2
        else
            printf 'export DBUSER=%s\n' "$_dbuser"
        fi
    fi
} > "$REPO_PATH/.env"

# Refresh the prod connectivity section of etc/reuter.ini from
# etc/machines.ini. gen-reuter exits 0 (with a warning) when there is no
# [prod] database host, so a fresh repo without a prod mapping is safe.
if command -v gen-reuter >/dev/null 2>&1; then
    ( cd "$REPO_PATH" && gen-reuter )
elif [ -x "$REPO_PATH/bin/gen-reuter" ]; then
    ( cd "$REPO_PATH" && "$REPO_PATH/bin/gen-reuter" )
fi

echo "    Created $REPO_PATH/.env (dev: REPO_PATH=$REPO_PATH, EMA_TARGET=sandbox)"
