#!/usr/bin/env bash
# Create .env (git-ignored) with the machine configuration:
#   - REPO_PATH/REPO_LOG: runtime paths consumed by phprun and the
#     framework's Database class (derived here, never in etc/dev.conf);
#   - the consumer-chosen dev values (export-style shell, sourced below and
#     relayed verbatim into .env): DBUSER (consumer policy) and SSL_DIR (the
#     machine's TLS client-cert directory).
# EMA_TARGET is deliberately NOT written: unset means prod (the app layer's
# default), so sandbox stays an explicit opt-in (`EMA_TARGET=sandbox`).
#
# The dev MariaDB instance is NOT initialized or started here: ema owns the
# per-instance sandbox lifecycle (`ema sandbox` / `ema start` / `ema stop`),
# so no MYSQL_* paths are written to .env anymore — and no REUTER_INI either:
# under EMA_TARGET=sandbox the app layer resolves its config itself, from
# var/sandbox/<name>-<GUID>/reuter.ini in the working directory.
#
# Config resolution (two layers, merged): the committed etc/dev.default.conf
# (tracked, read as a fallback so a plain checkout works) is sourced first,
# then the optional git-ignored etc/dev.conf (the override, sourced last, wins).
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

DEV_DEFAULT_CONF="$REPO_PATH/etc/dev.default.conf"
DEV_CONF="$REPO_PATH/etc/dev.conf"

# Start from a clean slate: the committed default and the optional override are
# the only sources for these keys (no ambient DBUSER/SSL_DIR leaks in).
unset DBUSER SSL_DIR

# Source the committed default, then the optional git-ignored override. Both are
# export-style shell; the override wins (sourced last) and may set a key empty
# to clear a defaulted value.
for f in "$DEV_DEFAULT_CONF" "$DEV_CONF"; do
    [[ -f "$f" ]] || continue
    set -a
    # shellcheck disable=SC1090
    . "$f"
    set +a
done

# DBUSER: absent -> the mechanism default ($USER); present-but-empty -> a loud
# error (a username must be non-empty).
if [[ -z "${DBUSER+x}" ]]; then
    DBUSER="$USER"
elif [[ -z "$DBUSER" ]]; then
    echo "Error: DBUSER is set but empty in etc/dev.conf (a username is required)." >&2
    exit 1
fi

# SSL_DIR: absent/empty -> no client cert (plain TCP); non-empty -> must be an
# absolute path after shell expansion (a quoted ~ now fails loudly here).
case "${SSL_DIR:-}" in
    "") ;;
    /*) ;;
    *)  echo "Error: SSL_DIR '$SSL_DIR' is not an absolute path (etc/dev.conf)." >&2
        exit 1
        ;;
esac

{
    printf 'export REPO_PATH=%s\n' "$REPO_PATH"
    printf 'export REPO_LOG=%s\n' "$REPO_LOG"
    # DBUSER is now always non-empty (file value or the $USER fallback).
    printf 'export DBUSER=%s\n' "$DBUSER"
    if [ -n "${SSL_DIR:-}" ]; then
        printf 'export SSL_DIR=%s\n' "$SSL_DIR"
    fi
} > "$REPO_PATH/.env"

echo "    Created $REPO_PATH/.env (dev: REPO_PATH=$REPO_PATH)"
