#!/usr/bin/env bash
# Create .env (git-ignored) with the machine configuration:
#   - REPO_PATH/REPO_LOG: runtime paths consumed by phprun and the
#     framework's Database class;
#   - EMA_TARGET=sandbox: mode signal for the Database class (the app layer
#     resolves the local sandbox instance instead of a prod reuter.ini) and
#     for ema's dbname-addressed verb (`ema mariadb <db>` picks the sandbox
#     instance in this shell);
#   - DBUSER: this machine's team member name, resolved from etc/team.ini
#     (the section whose entries include the local hostname; skipped with a
#     warning when no mapping exists). Needed for remote access to prod only.
#
# The dev MariaDB instance is NOT initialized or started here: ema owns the
# per-instance sandbox lifecycle (`ema sandbox` / `ema start` / `ema stop`),
# so no MYSQL_* paths are written to .env anymore — and no REUTER_INI either:
# under EMA_TARGET=sandbox the app layer resolves its config itself, from
# var/sandbox/<name>-<GUID>/reuter.ini in the working directory.
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

# Private config is consumer-owned: the framework neither fetches nor injects
# it, so the real etc/team.ini (read below for DBUSER) must already be in the
# checkout — see doc/system/consumer-config.md.

{
    printf 'export REPO_PATH=%s\n' "$REPO_PATH"
    printf 'export REPO_LOG=%s\n' "$REPO_LOG"
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

echo "    Created $REPO_PATH/.env (dev: REPO_PATH=$REPO_PATH, EMA_TARGET=sandbox)"
