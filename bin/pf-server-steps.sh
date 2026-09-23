#!/usr/bin/env bash
# pf-server-steps — framework's per-host server steps, run on the prod host by
# pf-deploy.sh after the repo swap + provision.
#
# Values come from the replayed deploy.conf environment (see pf-deploy.sh);
# a consumer that commits a real etc/deploy.conf still overrides them (the
# file is sourced only when present). It runs: gen-env (regenerate .env),
# db-check (warn-only reachability), and — on every host — the scope-filtered
# cron-manifest install (only when the repo declares #[CronJob] jobs).
#
# Usage: vendor/bin/pf-server-steps.sh   (root, from the deployed repo root)

set -euo pipefail

# CWD is the deployed repo root (pf-deploy.sh cds there first).
if [[ -f ./etc/deploy.conf ]]; then
    set -a
    # shellcheck disable=SC1091
    . ./etc/deploy.conf
    set +a
fi

export PATH="$DEPLOY_TARGET_DIR/vendor/bin:$DEPLOY_NIX_RESULT_DIR/result/bin:$PATH"

echo "    Regenerating production .env..." >&2
gen-env
echo "    Verifying database connectivity (warn-only)..." >&2
db-check --reuter-ini "$DEPLOY_REUTER_INI"

# Cron install runs on every host, filtered by this host's own tag list
# (HOST_TAGS, replayed by pf-deploy.sh): a job is emitted only when its scope
# is `host` or an exact element of the list. Skipped entirely when the repo
# declares no #[CronJob] jobs.
if grep -Rqs '#\[CronJob' "$DEPLOY_TARGET_DIR/src"; then
    if [ -z "${CRON_FILE:-}" ]; then
        echo "pf-deploy: this repo declares #[CronJob] attributes but deploy.conf sets no CRON_FILE." >&2
        exit 1
    fi
    # Cron entries need both phprun (vendor/bin) and php (nix result bin) on
    # PATH; CRON_NIX_BIN becomes the crontab NIX_BIN= assignment prepended to
    # every entry. Consumers may override it in deploy.conf.
    export CRON_NIX_BIN="${CRON_NIX_BIN:-$DEPLOY_TARGET_DIR/vendor/bin:$DEPLOY_NIX_RESULT_DIR/result/bin}"
    echo "    Updating cron jobs from #[CronJob]/#[Agent] attributes..." >&2
    cron-manifest --host-tags "${HOST_TAGS:-}" > "$CRON_FILE"
    chmod 644 "$CRON_FILE"
    systemctl restart cron 2>/dev/null || systemctl restart crond
    echo "    Cron jobs installed to $CRON_FILE."
fi
