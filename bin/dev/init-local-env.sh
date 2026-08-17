#!/usr/bin/env bash
# Create .env (git-ignored) with the full machine configuration:
#   - REPO_PATH/REPO_LOG/REUTER_INI + EMA_TARGET: runtime config consumed
#     by phprun and the framework's Database class (framework contract);
#   - MYSQL_*: derived from the target dir (pure path arithmetic); consumed
#     by the dev shell bootstrap (shell-enter.sh) and the Makefile;
#   - DBUSER: mapped for this machine in etc/dev-machines.ini (needed for
#     remote access to prod; skipped with a warning when the mapping does
#     not exist).
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
    printf 'export REUTER_INI=%s/etc/reuter.ini\n' "$REPO_PATH"
    printf 'export EMA_TARGET=local\n'

    if [ ! -f "$REPO_PATH/etc/dev-machines.ini" ]; then
        echo "WARNING: $REPO_PATH/etc/dev-machines.ini not found. Skipping DBUSER (needed for remote access only)." >&2
    else
        _dbuser=$(grep "^$(hostname)=" "$REPO_PATH/etc/dev-machines.ini" | cut -d= -f2)
        if [ -z "$_dbuser" ]; then
            echo "WARNING: hostname '$(hostname)' not found in $REPO_PATH/etc/dev-machines.ini. Skipping DBUSER (needed for remote access only)." >&2
        else
            printf 'export DBUSER=%s\n' "$_dbuser"
        fi
    fi
} > "$REPO_PATH/.env"

echo "    Created $REPO_PATH/.env (dev: REPO_PATH=$REPO_PATH, EMA_TARGET=local)"
