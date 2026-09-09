# worker tag: cron + env steps built into pf-deploy — Plan & Progress

Date: 2026-09-09
Repos: php_daas_framework (this repo, mechanism). Consumer-side data and
       wrapper changes are tracked in each consumer's own plan doc.

## Decision

Flip deploy ownership: the framework's `pf-deploy.sh` now runs the per-host
runtime-env steps itself — `gen-env` + `gen-reuter` on **every** host, and
the `cron-manifest` install on hosts carrying the bare `worker` tag —
instead of leaving `.env` regeneration and cron installation to each
consumer's deploy wrapper. `worker` becomes a framework built-in tag next to
`db` (a bare flag; the `tag[:name]` grammar is unchanged, and every other tag
stays consumer-owned).

This supersedes the consumer-owned `worker` deploy step introduced by the
2026-08-31 deploy-step-tags decision: consumers no longer re-implement
`.env`/cron installation per project. Cron-capable projects only carry the
`worker` token in `etc/machines.ini` and the `CRON_FILE`/`CRON_USER` values
in the committed `etc/deploy.conf`; `pf-deploy.sh` does the rest on every
deploy.

Per-host order inside `deploy_to_host()` (after the optional consumer
`DEPLOY_INIT_CMD`), one remote root run from the deployed repo root:

1. source the deployed `etc/deploy.conf`; put
   `$DEPLOY_TARGET_DIR/vendor/bin` (framework CLIs) and
   `$DEPLOY_NIX_RESULT_DIR/result/bin` (php + env binaries) on `PATH`;
2. `mkdir -p /etc/<instance>` (fixes the latent gap where `gen-reuter`
   would fail on app-only hosts that lack the config dir);
3. `gen-env` — regenerate the git-ignored `.env` (deterministic projection;
   the repo swap wiped the previous one);
4. `gen-reuter /etc/<instance>/reuter.ini` — refresh the prod
   `[<dbname>]` connectivity sections (preserving `*_PASSWORD` keys);
5. if the host's token list carries bare `worker`: fail loudly when
   `CRON_FILE` is unset, default `CRON_NIX_BIN` to
   `$DEPLOY_TARGET_DIR/vendor/bin:$DEPLOY_NIX_RESULT_DIR/result/bin` (both
   `phprun` and `php` must resolve for the cron entries), install
   `cron-manifest` output into `CRON_FILE` (chmod 644), restart cron.

Guarantees preserved: `.env` regeneration always precedes the cron install
within the same run; the framework CLIs still own the *generation* surface
(`#[CronJob]`/`#[Agent]`, `gen-env`, `gen-reuter`, `cron-manifest`). A local
fail-fast check mirrors the remote `CRON_FILE` guard before anything is
shipped to a `worker` host. Nothing has been deployed to production yet, so
no live-host migration is involved.

## Changes

### php_daas_framework (this repo)

- [x] `bin/pf-deploy.sh` — `deploy_to_host()` detects bare `worker` (next to
      `db:`), fails fast locally when a worker host's `etc/deploy.conf` sets
      no `CRON_FILE`, and runs the built-in server steps (heredoc snippet
      above) after `DEPLOY_INIT_CMD`; header comments updated (`worker` =
      second built-in tag).
- [x] `bin/pf-roster` — header grammar/comment: `db` (named) and `worker`
      (bare) are the built-in tags. No behavior change.
- [x] `bin/cron-manifest` — header: output installed by `pf-deploy` on
      `worker`-tagged hosts.
- [x] `src/cron_manifest.php` — header comments (installer + `CRON_NIX_BIN`
      default surface). No behavior change.
- [x] `etc/machines.ini.template` — comment block + examples declare `worker`
      as a framework built-in (cron install on every deploy).
- [x] `etc/deploy.conf.template` — `gen-env` comment now names `pf-deploy`;
      `CRON_*` block rewritten (consumed by the built-in worker step,
      `CRON_NIX_BIN` optional override documented).
- [x] `README.md` — built-in-tag statements (`db` + `worker`), `.env`/cron
      ownership paragraphs, config-table `CRON_FILE` row, wrapper example
      shrunk to consumer-owned tags, `gen-env`/`cron-manifest` bullets.
- [x] `doc/system/ema.md` — deploy-chain section: built-in server steps.
- [x] `doc/plans/2026-09-09-worker-cron-builtin.md` — this doc.

Consumer-side changes (pin bump + wrapper shrink + docs) are tracked in each
consumer's own dated plan doc.

## Open items

- First production deploys are still pending (no `[prod]` roster populated
  yet): the private-config overlay deploy and the new built-in server steps
  must coexist on a live host — ordering (config overlay vs. `pf-deploy`
  server steps) is documented per consumer and will be exercised on the
  first real host.
- `gen-reuter` gracefully no-ops when no `db:` tokens are readable on the
  host (e.g. before the private config lands): unchanged semantics, message
  only.
- `CRON_NIX_BIN` default moved framework-side (`vendor/bin` + nix result
  bin); consumers that previously overrode it can keep doing so via
  `etc/deploy.conf`.
