# Database resolves sandbox vs prod via EMA_TARGET — Plan & Progress

Date: 2026-09-25
Repos: php_daas_framework (this repo); ../ema (upstream, reference only).
       Consumer-side data changes are tracked in each consumer's own plan.

## Decision

Make `EMA_TARGET` the single mode switch for the app layer (`Database`), not
just the `ema` CLI. Today `Database` is prod-only: `REUTER_INI` (env-first) →
else `$PWD/etc/reuter.ini`, and there is no sandbox path, so an agent running
app-layer code (`phprun`) can only hit the single prod-shaped file. `ema`
already encodes the mode contract we want — `sandbox` → the per-instance
`var/sandbox/<name>-<GUID>/reuter.ini`, `prod` → `REUTER_INI`/`etc/reuter.ini`
— so the app layer adopts the same contract plus a sandbox connection path.

Two design decisions, both resolved here:

- **Sandbox instance resolution** — resolve by dbname, mirroring `ema`'s
  `_resolve_instance`: given `$dbname`, glob `var/sandbox/<dbname>-*/reuter.ini`
  and require exactly one match (error with a full-`<name>-<GUID>` hint on
  zero/multiple). No new "current" pointer, no `ema` change. This closes the
  deferred "dev app-layer wiring" (Open items of
  `doc/plans/2026-09-07-ema-schema-only-and-service-users.md`) by making the
  resolution per-dbname + uniqueness, exactly as `ema` already does.
- **Sandbox auth** — in sandbox mode connect as `root` over the instance's
  `MYSQL_UNIX_PORT` (read from the sandbox section) with an empty password, the
  same way `ema` runs DDL against a sandbox (`_run_root_sql`,
  `mariadb-admin -u root --socket=…`). The sandbox is a user-owned local
  MariaDB; the `$account` argument is prod-only and ignored in sandbox mode. No
  credential injection into the sandbox ini, no consumer-side service-user
  provisioning for sandbox.

Naming: the app layer's entry point is `Database::connectTo()`, not
`connect()`. PHP 8.4 (the version this repo pins in `flake.nix`) added a static
`PDO::connect()`, and `Database extends PDO`, so a same-named
`connect($dbname, $account)` is a fatal incompatible-signature error. The
`connectTo` / `connectAs` / `connectSandbox` family and the contract below are
otherwise unchanged.

`Database::connectTo()` defaults unset/empty `EMA_TARGET` to `prod`
(backward-compatible with today's app layer); `sandbox` is an explicit
`EMA_TARGET=sandbox`. The prod path is otherwise unchanged: `connectAs` keeps
reading `SERVER`/`PORT` over TCP and `MYSQL_UNIX_PORT` from `.env` (which stays
MYSQL_*-free), so prod remains TCP-only.

## Mechanism & data ownership

| File | Owner | Role |
|---|---|---|
| `var/sandbox/<name>-<GUID>/reuter.ini` | `ema` (write) | sandbox endpoint (`SERVER=localhost`, `PORT=0`, `DBNAME`, `MYSQL_UNIX_PORT`); now also read by the app layer |
| `etc/reuter.ini` | consumer (manual) | prod sections (`SERVER`/`PORT` + `<ACCOUNT>_PASSWORD`) |
| `.env` | `gen-env` (prod) / `init-local-env.sh` (dev) | carries `EMA_TARGET`; `REUTER_INI` only in prod |

`Database::connectTo($dbname, $account = '')`:

- `EMA_TARGET=sandbox` → `connectSandbox($dbname)` — root over the instance
  socket, `$account` ignored.
- `EMA_TARGET=prod` → `connectAs($dbname, $account)` — service account, throws
  when `$account` is empty.
- unset/empty → `prod` (`connectAs`).

## Changes

### php_daas_framework (this repo)

- [x] `src/Connectivity/Database.php` — add `sandboxConfigPath($dbname)` (replicate `ema` `_resolve_instance`: `var/sandbox/<dbname>-*/reuter.ini`, single match, clear zero/multiple errors), `connectSandbox($dbname)` (PDO `mysql:unix_socket=<MYSQL_UNIX_PORT>;dbname=<dbname>`, user `root`, empty password), and `connectTo($dbname, $account = '')` dispatcher (`sandbox` → `connectSandbox`; `prod` or unset/empty → `connectAs`, throwing on empty `$account`). Keep `connectAs` unchanged. (`connect` itself is unusable — PHP 8.4's static `PDO::connect`; see Decision.)
- [x] `src/phprun.php` — inject via `Database::connectTo($agent->dbTarget, $agent->dbAccount ?? '')`; drop the unconditional `dbAccount`-required guard (line 27-30) — account presence is now enforced by `connectTo()` in prod only.
- [x] `src/scripts/demo/db_smoke.php` — update the `connectAs` reference in the comment; note `dbAccount` is prod-only and the demo needs a `test-*` sandbox under `EMA_TARGET=sandbox`.
- [x] `bin/dev/init-local-env.sh` — drop the dangling `REUTER_INI=$REPO_PATH/var/reuter.local.ini` write (line 34) and its header mention (line 3); dev `.env` becomes REPO_PATH/REPO_LOG/EMA_TARGET=sandbox/DBUSER only.
- [x] `bin/dev/init-local-env.sh` — header (lines 3-5): `EMA_TARGET` is now "machine-mode signal for the `ema` CLI and the `Database` class", not "`ema` CLI only".
- [x] `etc/reuter.ini.template` — usage line (line 6) `connectAs` → `connectTo`; transport comment (lines 27-31): the app layer now reads the *sandbox* `MYSQL_UNIX_PORT` from the sandbox section, while prod stays TCP-only (unchanged).
- [x] `doc/system/agents.md` — `#[Agent]` table: `dbAccount` is required only under `EMA_TARGET=prod`; add that a bare `dbTarget` resolves to the local sandbox when `EMA_TARGET=sandbox`.
- [x] `doc/system/ema.md` — `EMA_TARGET` section (line 55+): now governs the app layer too; document the sandbox resolution + root-socket contract.
- [x] `doc/system/deploy.md` — environment contract: `EMA_TARGET` is app-layer-relevant; dev `.env` no longer carries `REUTER_INI`.
- [x] `doc/system/consumer-config.md` — sandbox ini is now read by the app layer; dev `.env` no longer sets `REUTER_INI`.

## Open items

- `connectTo()` defaults unset/empty → `prod`; ema's `_target()` uses the same
  default, so the two no longer diverge on an unset flag. ema later narrowed
  that flag to its dbname-addressed verb alone (its own follow-up plan,
  `doc/plans/2026-09-26-verb-scoped-ema-target.md`): the lifecycle verbs
  address sandbox instances by path, `status` prints both sides, and `drop` is
  retired. None of that touches the app-layer contract above, and
  `doc/system/ema.md` was updated to match.
- Prod `connectAs` keeps reading `MYSQL_UNIX_PORT` from `.env` (not the
  section), preserving the TCP-only prod contract — left unchanged
  deliberately; revisit only if a socket-based prod transport is ever wanted.
- ema's sandbox resolution/auth contract is unchanged by either change: one
  `var/sandbox/<name>-<GUID>/reuter.ini` per instance, name-addressed for the
  `mariadb` verb. Optionally note in its sandbox doc that the sandbox ini is
  also read by consumers' app layer (kept generic — no consumer names).
- Consumer-side caller migration (`connectAs` → `connectTo`) and the framework
  composer pin bump are tracked in each consumer's own plan.
