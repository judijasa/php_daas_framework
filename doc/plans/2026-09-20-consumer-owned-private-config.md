# Consumer-owned private config injection — Plan & Progress

Date: 2026-09-20
Repos: php_daas_framework

## Decision

Stop owning the private-config lifecycle. Source `etc/deploy.conf` and
`etc/reuter.ini` as plain files and fail clearly when one is missing; never
fetch, ship, symlink or warn about them — that pipeline is a consumer concern.
This reverses the 2026-09-19 "deploy.conf as private data" mechanism while
keeping the data move: real config lives in the consumer's private repo; the
public repo carries only templates.

The deploy swap still wipes `etc/`, so a generic pre-provision hook
(`DEPLOY_PRE_PROVISION_CMD`) runs on the host after swap + composer install and
before `pf-provision.sh`, with the sourced `deploy.conf` environment passed
through. The consumer supplies real `etc/deploy.conf` + `etc/machines.ini`
locally; `fetch-private-data` + `deploy-private-config` are deleted.

## Changes

- [x] `bin/pf-deploy.sh` — remove the local `fetch-private-data` call; replace
      the remote injection step with the `DEPLOY_PRE_PROVISION_CMD` hook
      (serialize the sourced `deploy.conf` env to the host); reword the header
      from "injected by fetch-private-data" to "real files provided by the
      consumer".
- [x] `bin/dev/init-local-env.sh` — drop the `fetch-private-data` call.
- [x] `bin/fetch-private-data`, `bin/deploy-private-config` — delete; remove
      both from `composer.json` `bin`.
- [x] `bin/pf-provision.sh`, `bin/gen-env`, `bin/cron-manifest`, `bin/db-check`
      — comment-only reword (they already source real files).
- [x] `etc/deploy.conf.template`, `etc/reuter.ini.template`, `README.md`,
      `doc/system/private-config.md` — reword: framework sources real `etc/`
      files; fetch/ship/inject is a consumer concern.

## Open items

- Serialization of the `deploy.conf` environment to the
  `DEPLOY_PRE_PROVISION_CMD` hook is settled in `pf-deploy.sh` during
  implementation.
