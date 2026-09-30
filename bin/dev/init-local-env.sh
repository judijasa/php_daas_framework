#!/usr/bin/env bash
# Create .env (git-ignored) with the machine configuration:
#   - REPO_PATH/REPO_LOG: runtime paths consumed by phprun and the
#     framework's Database class (derived here, never in etc/dev.conf);
#   - the consumer-chosen dev values from etc/dev.conf (export-style shell,
#     sourced below and relayed verbatim into .env): DBUSER (consumer policy)
#     and SSL_DIR (the machine's TLS client-cert directory).
# EMA_TARGET is deliberately NOT written: unset means prod (the app layer's
# default), so sandbox stays an explicit opt-in (`EMA_TARGET=sandbox`).
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

DEV_CONF="$REPO_PATH/etc/dev.conf"

# Source the consumer's dev config (export-style shell) when present. It holds
# only non-derived, consumer-chosen dev values (DBUSER, SSL_DIR, ...); the
# derived REPO_PATH/REPO_LOG above are never taken from it.
if [[ -f "$DEV_CONF" ]]; then
    set -a
    # shellcheck disable=SC1090
    . "$DEV_CONF"
    set +a
fi

{
    printf 'export REPO_PATH=%s\n' "$REPO_PATH"
    printf 'export REPO_LOG=%s\n' "$REPO_LOG"
    # Relay the consumer's dev values verbatim. The key set is the framework's
    # own mechanism and grows as the framework adds dev values; each is
    # optional (a consumer without a client cert simply omits SSL_DIR).
    if [ -n "${DBUSER:-}" ]; then
        printf 'export DBUSER=%s\n' "$DBUSER"
    fi
    if [ -n "${SSL_DIR:-}" ]; then
        printf 'export SSL_DIR=%s\n' "$SSL_DIR"
    fi
} > "$REPO_PATH/.env"

echo "    Created $REPO_PATH/.env (dev: REPO_PATH=$REPO_PATH)"
