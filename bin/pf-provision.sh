#!/usr/bin/env bash
# Generic production provisioning (framework mechanism).
#
# Runs as root on the remote via `deploy`, from the deployed repo
# root (the repo directory already exists — created by the deploy swap).
# Parameterized entirely by the committed etc/deploy.conf; the consumer owns
# the values, the framework owns the mechanism. Idempotent.
#
# The framework no longer provisions MariaDB: database instances are created
# by `ema create` at database-creation time (one instance per database), and
# the operator records the emitted connectivity in the consumer's manual
# reuter.ini (see doc/system/ema.md). This script only asserts the app user
# and creates the permanent system dirs.
#
# What this covers:
#   1. Assert the app user (PROD_USER) exists — creation and SSH access are
#      documented pre-deploy prerequisites (assert-only by design).
#   2. Create the permanent system dirs (log dir, deploy parent),
#      owned by PROD_USER.
#
# Consumer-specific extras (e.g. Apache/www-data traversal, app-specific
# state) belong in DEPLOY_INIT_CMD, which `deploy` runs after this
# script.
#
# Usage: pf-provision.sh   (root; config from etc/deploy.conf)

set -euo pipefail

set -a
. ./etc/deploy.conf
set +a

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

echo "Provisioning complete."
