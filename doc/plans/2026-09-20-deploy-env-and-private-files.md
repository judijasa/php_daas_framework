# Deploy env replay + private-file shipping — Plan & Progress

Date: 2026-09-20
Repos: php_daas_framework (this repo)

## Decision

Move the two remaining private-config responsibilities back into the framework,
partially reversing 2026-09-20-consumer-owned-private-config.md:

- **A — `deploy.conf` stops shipping to prod.** Its values are deploy-machine
  config (paths, app user, cron target). The deploy machine's `deploy.conf`
  environment is already serialized and replayed to the pre-provision hook;
  replay it to *every* post-swap remote step instead, and let the host-side
  scripts read the file only when a consumer commits one. Prod no longer holds a
  `deploy.conf`.
- **B — the framework ships the consumer's declared private files.** A new
  `DEPLOY_PRIVATE_FILES` key (space-separated `etc/`-relative names) is tarred
  from the deploy machine's `etc/` and extracted into the freshly swapped
  `etc/` in one post-swap step — replacing the consumer's own ship-to-stable-dir
  + `DEPLOY_PRE_PROVISION_CMD` restore dance. The hook stays for consumers that
  still want it.

Out of scope: committed-only guarantees via `git archive` of the private repo
(the framework now ships whatever the consumer materialized into `etc/`), DB
instance provisioning, and `machines.ini`/`team.ini`.

## Config model

| key | where | role |
|---|---|---|
| `etc/deploy.conf` | deploy machine only | source of the `DEPLOY_*` env, replayed to the host |
| `DEPLOY_PRIVATE_FILES` | in `deploy.conf` | `etc/`-relative files the framework ships + injects |
| `DEPLOY_PRE_PROVISION_CMD` | in `deploy.conf` | optional consumer hook (kept) |

## Changes

### php_daas_framework (this repo)

- [x] `bin/pf-deploy.sh` — replay the serialized `deploy.conf` env to the
      provision, `DEPLOY_INIT_CMD` and server-steps invocations (convert them to
      `bash -s` heredocs); add the `DEPLOY_PRIVATE_FILES` ship step after the
      swap; replace the hard `etc/deploy.conf`-exists check with a
      required-`DEPLOY_*`-present check; reword the header.
- [x] `bin/pf-server-steps.sh` — new: extract the inline server steps (gen-env,
      db-check, cron install); source `./etc/deploy.conf` only when present.
- [x] `bin/pf-provision.sh`, `bin/gen-env` — source `etc/deploy.conf` only when
      present (env replay supplies the values otherwise).
- [x] `composer.json` — add `bin/pf-server-steps.sh` to `bin`.
- [x] `etc/deploy.conf.template` — document `DEPLOY_PRIVATE_FILES`; reword
      `DEPLOY_PRE_PROVISION_CMD` as optional alongside shipping.
- [x] `doc/system/consumer-config.md` — rewrite the production-delivery section
      (framework ships `DEPLOY_PRIVATE_FILES`; `deploy.conf` is deploy-machine
      env, not a prod file).
- [x] `doc/plans/2026-09-20-deploy-env-and-private-files.md` — this doc.

## Open items

- Lock-sync with consumers (framework commit → consumer `composer.json` bump +
  `composer install`).
- Full end-to-end deploy not run here (needs nix + a live host + private data);
  validation is `bash -n` plus unit-style smoke tests of the edited scripts.
