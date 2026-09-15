# Framework private-config deploy — Plan & Progress

Date: 2026-09-14
Repos: php_daas_framework (this repo).

## Decision

Move the deployment of a consumer's private operational config into the
framework as a generic CLI, replacing each consumer's own private-repo
`bin/deploy.sh`. The mechanism ships **whole files only** — no inner
filtering and no `reuter.ini` section splicing. With passwordless, host-pinned
service accounts, the only thing a spliced `reuter.ini` would hide is internal
IP/port topology, which is not a security boundary.

Prod deploys **committed config only**: the private source is shipped via
`git archive <ref>`, never from a dirty working tree or loose git-ignored
files.

`.private-source` accepts **`PRIVATE_DATA_GIT`** (+ `PRIVATE_DATA_REF`) only:
`PRIVATE_DATA_SOURCE` is dropped, and so is the "private files already in
`etc/`" fallback. The private repo's committed content is the single source of
truth on every machine that can reach git, so no machine runs on a loose,
uncommitted copy of the private config — the restriction exists to discourage
deploying anything but committed configuration. An absent `.private-source`
stays a no-op (the public repo works without private data); a present one that
sets no `PRIVATE_DATA_GIT` is an error, not a silent skip.

Prod has no git, so it holds no `.private-source`: the stable per-app private
dir is named by `deploy.conf`'s `DEPLOY_PRIVATE_CONFIG_DIR` instead. The
committed-only guarantee on prod comes from the deploy machine, which ships
`git archive` output.

The app layer stays TCP: `Database.php` resolves the `[<dbname>]` section from
`reuter.ini` and connects over `SERVER`/`PORT`, while `MYSQL_UNIX_PORT` in the
section is `ema`-only. So `reuter.ini` is required on every prod host even when
a database is colocated — the file ships whole, to every host.

On prod, `reuter.ini` is the only private file a host needs, so it is the only
one that ever leaves the private repo for a host:

- `team.ini` is dev-only (`gen-cert` / `gen-grants` /
  `gen-service-accounts` / `init-local-env`) — never shipped to prod.
- `machines.ini` becomes deploy/dev-time only — `db-check` stops reading it
  (the instance set comes from the host's own `mariadb@*` units) — never
  shipped to prod.

`fetch-private-data` stays in prod, symmetric with dev: both environments
symlink the private source into `etc/`. Dev's source is the on-demand clone in
`var/private-data`; prod's is the stable per-app dir named by
`DEPLOY_PRIVATE_CONFIG_DIR`.

## Mechanism & data ownership

The framework owns the mechanism; the consumer owns the data (the private
files and the stable-dir location, named in the consumer's committed
`deploy.conf`).

Per host, prod private-config delivery is:

1. `bin/deploy-private-config` ships `reuter.ini` (whole) to the stable
   per-app private dir on the host, from the private config repo's committed
   content (`git archive <ref>`), and ships **nothing else** — `machines.ini`
   and `team.ini` are never copied to a host. It reads the `[prod]` roster
   from `etc/machines.ini` **locally** (deploy machine); `machines.ini` is
   never shipped.
2. `bin/pf-deploy.sh`, after the repo swap and before `gen-env`/`db-check`,
   runs `fetch-private-data` on the remote so it symlinks the stable dir's
   `reuter.ini` into the freshly swapped `etc/reuter.ini`.
3. `bin/fetch-private-data` has exactly one required file, `reuter.ini`; the
   `machines.ini` abort gate goes away. `machines.ini`/`team.ini` are wired
   only when the source provides them — which is dev alone, where `team.ini`
   feeds `gen-cert`/`gen-grants`/`init-local-env` and `machines.ini` feeds the
   local deploy roster. Prod's source holds `reuter.ini` by construction
   (Mechanism 1), so prod wires `reuter.ini` and nothing else. There is no
   loose-file `etc/` fallback: an absent `.private-source` is a no-op, and a
   present one without `PRIVATE_DATA_GIT` is an error. On prod — no git, no
   `.private-source` — it resolves the stable dir from
   `DEPLOY_PRIVATE_CONFIG_DIR`.
4. In git mode the injection is a **symlink**, not a copy: `etc/<f>` points
   into `var/private-data/<f>`, so a later `fetch-private-data` refreshes the
   data through the link and no re-linking is needed. A real file at `etc/<f>`
   shadows the private data instead — it must be reported loudly, never
   skipped silently (that silent skip is how a machine ends up running stale
   private config while believing it is current).
5. `bin/db-check` derives the host's databases from the `mariadb@<db>`
   systemd units (the unit name is the db name) instead of
   `pf-roster --db-servers`, removing the last prod-side read of
   `machines.ini`.

## Changes

### php_daas_framework (this repo)

- [x] `bin/deploy-private-config` (new) — ship `reuter.ini` (whole) to the
      stable per-app private dir on each `[prod]` host from committed content
      (`git archive <ref>`), and **nothing else**: no `machines.ini`, no
      `team.ini`.
- [x] `bin/pf-deploy.sh` — run `fetch-private-data` on the remote after the
      repo swap, before `gen-env`/`db-check`, so `reuter.ini` lands in the
      fresh `etc/`.
- [x] `bin/fetch-private-data` — `reuter.ini` is the only required file (drop
      the `machines.ini` abort gate); `machines.ini`/`team.ini` are wired only
      when the source provides them (dev). Accept `PRIVATE_DATA_GIT` (+
      `PRIVATE_DATA_REF`) only: drop `PRIVATE_DATA_SOURCE` and the loose-file
      `etc/` fallback, and fail on a `.private-source` that sets no
      `PRIVATE_DATA_GIT` (an absent `.private-source` stays a no-op). Resolve
      the prod stable dir from `DEPLOY_PRIVATE_CONFIG_DIR`. Handle each
      destination per the wire invariant (Mechanism 4): keep an up-to-date
      link, re-point a stale or dangling one, and warn loudly — never
      overwrite — when `etc/<f>` is a real file.
- [x] `.private-source.example` — document the single git mechanism (drop the
      `PRIVATE_DATA_SOURCE` line and the "already in `etc/`" paragraph).
- [x] `etc/deploy.conf.template` — document `DEPLOY_PRIVATE_CONFIG_DIR` (the
      stable per-app private dir on the host) next to `DEPLOY_REUTER_INI`.
- [x] `bin/dev/pf-shell-enter.sh` — best-effort private-config refresh at dev
      shell entry, so the checkout is not stale for the whole session: guarded
      by `.private-source`, `GIT_TERMINAL_PROMPT=0`, never fatal (a trailing
      `:` keeps shell entry from failing), stdout quiet, warnings on stderr
      visible.
- [x] `Makefile` — drop the duplicate `_dev-init-fetch-private-data` step
      (`bin/dev/init-local-env.sh` already runs `fetch-private-data`).
- [x] `bin/db-check` — replace the roster-derived instance set
      (`pf-roster --db-servers` + `--host`) with direct `mariadb@*` unit
      enumeration; drop the `machines.ini` dependency and the
      declared-missing / orphan cross-checks.
- [x] `composer.json` — add `bin/deploy-private-config` to the `bin` array.
- [x] `doc/system/private-config.md` — rewrite the production-deploy path to
      the new mechanism (`reuter.ini` is the only file shipped, whole;
      `machines.ini`/`team.ini` stay dev-side), reduce the three retrieval
      modes to the single git one, record the wire invariant, and collapse the
      two extraction-path stories into one.
- [x] `doc/system/ema.md` — update the `db-check` description (instance check
      is unit-driven, no longer roster-driven).
- [x] `doc/plans/2026-09-14-framework-private-config-deploy.md` — this doc.

## Open items

- Confirm prod hosts have no git (the prod half of the design rests on it). If
  git were available on prod, `.private-source` with `PRIVATE_DATA_GIT` would
  work there too, `DEPLOY_PRIVATE_CONFIG_DIR` would be unnecessary, and dev and
  prod would share one source mechanism.
- Whether consumer repos keep a committed `etc/` at all (dropping it in favour
  of the config repo entirely) — deferred; the git-only rule above only
  discourages *uncommitted* private config.
- Confirm `ema`'s `mariadb@<db>` unit name always equals the database name
  (the `db-check` workaround depends on it).
- Confirm no remaining prod path reads `machines.ini` after the `db-check`
  change (`pf-deploy.sh` and `deploy-private-config` read it only locally).
