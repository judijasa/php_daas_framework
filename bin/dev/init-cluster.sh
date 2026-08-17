#!/usr/bin/env bash
# Initialize the local, isolated MariaDB cluster used by the dev sandbox and
# start its daemon if the data dir is empty.
# Backend for the Makefile target _dev-init-cluster (make dev-init).
# Shipped in the framework's nix package so consumers call it from their own
# dev-init chain (it is fully parameterized; consumer data stays in the
# consumer's Makefile variables).
# Usage: init-cluster.sh <data-dir> <pid-file> <unix-socket>

set -euo pipefail

DB_DATA_DIR="$1"
DB_PID_FILE="$2"
DB_UNIX_SOCKET="$3"

echo "Initializing raw MariaDB cluster structures..."
if [ ! -d "$DB_DATA_DIR" ]; then
    # No --basedir: The binary auto-detects its compiled-in prefix
    mariadb-install-db --auth-root-authentication-method=normal --datadir="$DB_DATA_DIR" --pid-file="$DB_PID_FILE" > /dev/null 2>&1
    echo "    Starting MariaDB daemon..."
    mysqld --datadir="$DB_DATA_DIR" --pid-file="$DB_PID_FILE" --socket="$DB_UNIX_SOCKET" --skip-networking > /dev/null 2>&1 &
else
    echo "    MariaDB cluster already initialized. Skipping."
fi
