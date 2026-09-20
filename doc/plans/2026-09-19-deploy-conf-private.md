# deploy.conf as private data — Plan & Progress

Date: 2026-09-19
Repos: php_daas_framework (this repo, mechanism); consumers (data).

## Decision

The framework stops treating `etc/deploy.conf` as a committed, project-static
file. It becomes private data on the same footing as `reuter.ini`, because the
deploy flow *sources* it in several places — `pf-provision.sh`, the per-host
server steps and `cron-manifest` on the host, and `fetch-private-data` itself —
so the file must be delivered and injected before anything reads it instead of
being shipped inside the repo.

Delivery reuses the existing two-step private-config split unchanged:
`deploy-private-config` ships `deploy.conf` + `reuter.ini` (whole, from the
private repo's committed content) to the stable per-app dir on every `[prod]`
host, and `pf-deploy.sh` runs `fetch-private-data` on the host right after the
repo swap — now *before* `pf-provision.sh` and the server steps that source
`etc/deploy.conf`, instead of after the provisioning.

Committing the file stays supported for a project that runs without private
data: `deploy.conf` is then required in the repo and absent from the private
one, and the injection is skipped. `deploy-private-config` ships it only when
the private repo has it.

## Mechanism & data ownership

| Surface | Owner | Notes |
|---|---|---|
| `etc/deploy.conf.template` | framework | documents both placements; placeholder values |
| `etc/deploy.conf` | consumer | private data: injected, or committed for a project without private data |
| `fetch-private-data` | framework | wires `deploy.conf` + `reuter.ini` (+ the dev-only files); `deploy.conf` is required unless the repo carries a committed copy |
| `deploy-private-config` | framework | ships `deploy.conf` + `reuter.ini`; nothing else leaves the deploy machine |
| `pf-deploy.sh` | framework | injects the private config after the repo swap, before provisioning and the server steps |

## Changes

### php_daas_framework (this repo)

- [x] `bin/fetch-private-data` — `deploy.conf` added to the wired file list
      (first) and required unless the repo carries a committed copy; the prod
      branch resolves the stable dir from the environment's
      `DEPLOY_PRIVATE_CONFIG_DIR`, falling back to an already-injected
      `etc/deploy.conf`.
- [x] `bin/deploy-private-config` — ships `deploy.conf` when the private repo
      has it (`reuter.ini` stays the always-required file); a missing
      `etc/deploy.conf` now points at the private channel instead of advising a
      committed copy.
- [x] `bin/pf-deploy.sh` — new injection step right after the repo swap, with
      `DEPLOY_PRIVATE_CONFIG_DIR` passed explicitly; the old server-step
      `fetch-private-data` call is dropped, so the injection now precedes
      `pf-provision.sh`.
- [x] `bin/gen-env`, `bin/pf-provision.sh`, `bin/cron-manifest` — header
      comments: `etc/deploy.conf` is injected private data.
- [x] `etc/deploy.conf.template` — header rewritten: private data injected via
      `.private-source`, with the committed placement documented as the
      without-private-data alternative.
- [x] `.gitignore` — ignore `/etc/deploy.conf`.
- [x] `doc/system/private-config.md` — table row; two private files reach a
      host; the two-step delivery and the required-file invariant.
- [x] `README.md` — standalone prod init, the `pf-deploy.sh` config surfaces,
      the `fetch-private-data`/`deploy-private-config` descriptions and the
      `gen-env` projection.
- [x] `doc/plans/2026-09-19-deploy-conf-private.md` — this doc.

## Open items

- **Missing stable dir on a host** — `fetch-private-data` still exits 0 when
  `DEPLOY_PRIVATE_CONFIG_DIR` does not exist, so the deploy fails later in
  `pf-provision.sh` with a less direct message. Revisit if that proves too
  indirect.
- **`host-hardening.php`** — stays deploy/dev-time only; **no** change to what
  ships to a host.
