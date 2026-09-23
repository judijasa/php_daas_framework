# Cron job scope: host vs tag — Plan & Progress

Date: 2026-09-23
Repos: php_daas_framework (this repo, mechanism). Consumer-side data and
       attribute changes are tracked in each consumer's own plan doc.

## Decision

`#[CronJob]` gains a **required** `scope` argument (no default). The value
matches the full `tag[:name]` grammar of `etc/machines.ini` [prod], plus one
reserved built-in:

- `host` — reserved: run on **every** prod host (host-maintenance jobs).
- any `tag[:name]` token — run on hosts whose [prod] entry carries that exact
  token (`worker`, `web`, `db:<name>`, …). Exact token equality; no wildcards.

`worker` is not special-cased in the matcher — it is an ordinary bare tag (the
value data jobs use); a job scoped `worker` runs only on `worker` hosts.

Every job must declare where it runs: `cron-manifest` fails loudly when a
`#[CronJob]` omits `scope`, and the pre-commit attribute hook rejects it, so a
job can never silently default to `worker` and miss its intended host. There
is no `none` scope — a job is disabled by commenting out its `#[CronJob]`
attribute (the existing convention).

Cron install moves from "`worker` hosts only" to "**every** host, filtered by
scope": `cron-manifest` gains `--host-tags <comma-list>` and emits only jobs
whose `scope` is `host` or is present in that list. `pf-deploy.sh` passes each
host's own normalized token list to `pf-server-steps.sh`, which runs the
filtered install on every host. `CRON_FILE` is required whenever the repo
declares any `#[CronJob]` attribute (cheap `grep '#\[CronJob' src/`); a
project with no cron jobs skips the install entirely, preserving the
forkable-template no-cron case.

`scope` lives on `#[CronJob]` (schedule = when, scope = where), keeping
`#[Agent]` for DB connectivity only (`dbTarget`/`dbAccount`).

## Scope model

| scope value | matches |
|---|---|
| `host` | every [prod] host |
| `worker` | hosts with the bare `worker` token |
| any `tag[:name]` | hosts whose [prod] entry carries that exact token |

`cron-manifest --host-tags <comma-list>` filters: a job is emitted iff
`scope === 'host'` or `scope` is an exact element of the comma list. No
`--host-tags` → emit all jobs (unchanged dev/debug behavior). `scope` is
required — a `#[CronJob]` without it is a hard error, not a default. Single
scope per job (see Open items).

## Changes

### php_daas_framework (this repo)

- [x] `src/CronJob.php` — add `public readonly string $scope` as a required
      constructor param (no default).
- [x] `src/cron_manifest.php` — parse `scope` from the `#[CronJob]` body and
      fail loudly when it is missing; add `--host-tags <comma-list>` filtering
      (emit iff `host` or exact-token match); header comment.
- [x] `hooks/check-php-attributes.php` — extend the existing
      "CronJob requires Agent" check with "CronJob requires scope".
- [x] `bin/cron-manifest` — header comment documents `--host-tags` passthrough
      (already `php "$RUNNER" "$@"`); no behavior change.
- [x] `bin/pf-server-steps.sh` — replace the `IS_WORKER_HOST`-gated cron block
      with an every-host block: run only when `grep -Rqs '#\[CronJob'` finds
      jobs in `$DEPLOY_TARGET_DIR/src`, guard `CRON_FILE`, then
      `cron-manifest --host-tags "${HOST_TAGS:-}" > "$CRON_FILE"` + restart
      cron.
- [x] `bin/pf-deploy.sh` — `deploy_to_host()`: drop the `IS_WORKER_HOST`
      loop; fail fast when `grep -Rqs '#\[CronJob' src/` is true and
      `CRON_FILE` is unset; pass `HOST_TAGS=$TAGLIST` to the remote server
      steps; header comments.
- [x] `bin/pf-roster` — header grammar comment: `tag[:name]` tokens double as
      cron scopes. No behavior change.
- [x] `etc/machines.ini.template` — comment block: tags are cron scopes;
      `host`-scoped jobs run on every host.
- [x] `etc/deploy.conf.template` — `CRON_FILE` comment: installed on every
      host (scope-filtered), required when the repo declares `#[CronJob]`.
- [x] `README.md` — `#[Agent]`/`#[CronJob]` bullet points to
      `doc/system/agents.md`; cron-install description (every host,
      scope-filtered).
- [x] `doc/system/agents.md` — NEW: `#[Agent]`/`#[CronJob]` argument reference
      (`dbTarget`/`dbAccount`, `schedule`/`scope` — scope required, scope
      grammar + matching).
- [x] `doc/plans/2026-09-23-cron-job-scope.md` — this doc.

## Open items

- **Multi-scope** (a comma list of tags per job) is deferred: single scope per
  job for now; revisit if a job must run on several disjoint tags.
- A host that matches no job gets an effectively empty crontab (the `NIX_BIN=`
  header only) — harmless; revisit only if it bothers operators.
- `--host-tags` (CLI flag) chosen over an env var for the filter surface; the
  flag keeps dev/manual `cron-manifest` runs backward compatible (emit all).
- Disabled jobs remain comment-out-based; no `none` scope value is introduced.
