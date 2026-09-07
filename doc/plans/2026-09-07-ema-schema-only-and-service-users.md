# ema schema-only model + service-user policy — Plan & Progress

Date: 2026-09-07
Repos: php_daas_framework (this repo); ../ema (upstream, reference only).
       Consumer-side data changes are tracked in each consumer's own plan.

## Decision

ema dropped its user/grants machinery and now provisions **schema only**:
`srv/<name>-<GUID>/upgrade.sql` placeholders shrink to `{{dbname}}`/
`{{charset}}`/`{{collation}}`, `default.php` carries just `$db` (`dbname`/
`charset`/`collation`) + `$dependencies`, the command surface becomes
`ema sandbox` (dev, per-instance) / `ema create` (prod, create-only) /
`ema mariadb <db> < file.sql` (raw SQL, no `apply`), and `EMA_MODE` is
renamed `EMA_TARGET` (`sandbox` | `prod`, binary).

The framework does **not** own service-user provisioning, and does **not**
name any service account. The accounts and their grants, plus the dedicated
provisioning script, are **consumer policy** and live in the consumer repo —
not here. The framework only connects as a named account:
`Utils\Connectivity\Database::connectAs($dbname, $account)` reads the generic
`<ACCOUNT>_PASSWORD` key (uppercased account name + `_PASSWORD`) from the
`[<dbname>]` reuter.ini section; the account name is supplied by the caller
(`#[Agent(dbTarget, dbAccount)]`, wired through `phprun`).

This supersedes the `ema apply <db> <sql>` surface assumed in
`doc/plans/2026-09-01-team-db-users.md` (raw SQL now goes through
`ema mariadb <db> < file.sql`).

## Mechanism & data ownership

| Owner | What it produces |
|---|---|
| ema (`ema sandbox` / `ema create`) | database + schema packages, topological order |
| consumer (own provisioning script) | service accounts + grants; persists `<ACCOUNT>_PASSWORD` keys |
| `gen-reuter` | prod `[<dbname>]` connectivity sections; preserves `*_PASSWORD` keys |

The provisioning script and the account names are consumer-owned. (A
`bin/gen-service-users` prototype was briefly drafted here, then removed —
account + grants creation belongs to the consumer repo, not this framework.)

## Changes

### php_daas_framework (this repo)

- [x] `src/Connectivity/Database.php` — replaced the three account-specific factories with one generic `connectAs($dbname, $account)`.
- [x] `src/Agent.php` — added `dbAccount` (account name passed alongside `dbTarget`).
- [x] `src/phprun.php` — injects via `Database::connectAs($dbTarget, $dbAccount)`; fails loudly when `dbTarget` is set without `dbAccount`.
- [x] `bin/gen-reuter` — preserves `*_PASSWORD` keys generically instead of naming accounts.
- [x] `src/scripts/demo/db_smoke.php` — `#[Agent(dbTarget, dbAccount)]` (demo uses a placeholder account name).
- [x] `bin/gen-service-users` — **removed** (provisioning is consumer-owned).
- [x] `composer.json` — **removed** `bin/gen-service-users` from the `bin` array.
- [x] `bin/gen-env` — `EMA_MODE=prod` → `EMA_TARGET=prod` (+ guard loop).
- [x] `bin/dev/init-local-env.sh` — `EMA_MODE=dev` → `EMA_TARGET=sandbox`.
- [x] `srv/test-D0PR2OGMHXDSCAR3/default.php` — new `$db` + `$dependencies`.
- [x] `srv/test-D0PR2OGMHXDSCAR3/upgrade.sql` — DDL-only, `{{dbname}}`/`{{charset}}`/`{{collation}}`.
- [x] `etc/reuter.ini.template` — generic `<ACCOUNT>_PASSWORD` contract (no named accounts).
- [x] `etc/deploy.conf.template` — `ema create srv/<name>-<GUID>` comment.
- [x] `README.md` — `ema sandbox`/`ema create`, `EMA_TARGET`, generic `Database::connectAs`.
- [x] `doc/system/ema.md` — rewrite for the schema-only model + account-agnostic connectivity.

## Open items

- Dev app-layer wiring: `init-local-env.sh` still writes
  `REUTER_INI=$PWD/var/reuter.local.ini`, but `ema sandbox` now writes
  `var/sandbox/<name>-<guid>/reuter.ini` (endpoint keys only, no passwords).
  Pointing dev `REUTER_INI` at the sandbox file and applying the consumer's
  service-user provisioning against it is the pending piece. **no** fix here
  yet — the per-instance path has no stable single default.
- Account naming, the provisioning script, and password storage (sandbox vs
  prod) are consumer policy — to be discussed in the consumer's own plan.
