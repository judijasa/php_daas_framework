#!/usr/bin/env bash
# Create .env (git-ignored) with the full machine configuration:
#   - REPO_PATH/REPO_LOG/REUTER_INI: runtime config consumed by phprun and
#     the framework's Database class (REUTER_INI -> var/reuter.local.ini);
#   - EMA_MODE=dev: machine-mode signal for the ema CLI only;
#   - MYSQL_*: derived from the target dir (pure path arithmetic); consumed
#     by the dev shell bootstrap (shell-enter.sh) and the Makefile;
#   - DBUSER: mapped for this machine in the [dev] section of
#     etc/machines.ini (needed for remote access to prod; skipped with a
#     warning when the mapping does not exist).
# Also refreshes etc/reuter.ini [prod] connectivity from etc/machines.ini via
# gen-reuter (when available).
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
MYSQL_BASE_DIR="$REPO_VAR/mariadb"
MYSQL_DATA_DIR="$MYSQL_BASE_DIR/data"
MYSQL_UNIX_PORT="$MYSQL_BASE_DIR/mysql.sock"
MYSQL_PID_FILE="$MYSQL_BASE_DIR/mysql.pid"

{
    printf 'export REPO_PATH=%s\n' "$REPO_PATH"
    printf 'export REPO_LOG=%s\n' "$REPO_LOG"
    printf 'export MYSQL_BASE_DIR=%s\n' "$MYSQL_BASE_DIR"
    printf 'export MYSQL_DATA_DIR=%s\n' "$MYSQL_DATA_DIR"
    printf 'export MYSQL_UNIX_PORT=%s\n' "$MYSQL_UNIX_PORT"
    printf 'export MYSQL_PID_FILE=%s\n' "$MYSQL_PID_FILE"
    printf 'export REUTER_INI=%s/var/reuter.local.ini\n' "$REPO_PATH"
    printf 'export EMA_MODE=dev\n'

    if [ ! -f "$REPO_PATH/etc/machines.ini" ]; then
        echo "WARNING: $REPO_PATH/etc/machines.ini not found. Skipping DBUSER (needed for remote access only)." >&2
    else
        _dbuser=$(awk -F= -v h="$(hostname)" '
            /^[[:space:]]*#/ { next }
            /^[[:space:]]*$/ { next }
            /^\[/ { sec = $1; next }
            sec == "[dev]" && $1 == h { print substr($0, index($0, "=") + 1); exit }
        ' "$REPO_PATH/etc/machines.ini")
        if [ -z "$_dbuser" ]; then
            echo "WARNING: hostname '$(hostname)' not found in the [dev] section of $REPO_PATH/etc/machines.ini. Skipping DBUSER (needed for remote access only)." >&2
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

echo "    Created $REPO_PATH/.env (dev: REPO_PATH=$REPO_PATH, EMA_MODE=dev)"
