# Typed PHP config classes — Plan & Progress

Date: 2026-09-27
Repos: php_daas_framework (this repo), ema (upstream, `../ema`).

## Decision

Migrate this repo's `default.php` files from the flat `$db`/`$dependencies`
arrays to instances of ema's typed `Ema\Config\*` value classes
(`DatabaseConfig`, `PackageConfig`, `RolesConfig`). ema is already a Composer
dependency (`judijasa/ema: dev-main`); the classes arrive via ema's new PSR-4
autoload mapping (see `../ema/doc/plans/2026-09-27-default-php-typed-classes.md`),
so no new dependency or tooling is introduced here — this repo already runs
PHPStan and Composer. This repo changes the config *shape* its packages author,
plus the two scripts that read those files directly: `gen-grants` and
`gen-service-accounts` `include` `default.php` and read the variables it
assigns, so they move to reading the returned object. `phprun` reads no
`default.php` and is unaffected.

One relocation lands with this migration: the roles/grants packages move
from `srv/` to `pkg/`. They are manifests, not database definitions — they
carry no `$db` — and ema's `srv/` now requires a `DatabaseConfig`, while
its `pkg/` manifest shape (`PackageConfig`) already carries `dependencies`
and the optional `RolesConfig`. `pkg/` is also the only root ema's resolver
searches, so the grants package's `roles-<GUID>` dependency stops being
resolvable by this repo's CLIs alone and becomes an ordinary `pkg/`
dependency. `srv/` is left holding database definitions only.

## Current state

- 6 `default.php` files: 1 `srv/` (`test-D0PR2OGMHXDSCAR3`) + 5 `pkg/`
  (`cursorseq-A1B2C3D4E5F60718`, `items-B2C3D4E5F6071829`,
  `demo-8C3A9E1F0D2B4C5D`, plus the relocated `roles-D04KGFJ8K9F5TFR2` and
  `test.roles-D0JBP3672U3UJFIP`). Today they author `$db = array(...)` and/or
  `$dependencies = array(...)`; the shared `roles` file carries the
  `//`-documented `$sources`/`$accounts`/`$allowlist` shape as comments only
  (`test.roles` is grants-only).
- PHPStan is already wired: `phpstan.dist.neon` (committed, `level: 5`,
  `paths: .`) is the inherited config; `phpstan.neon` is the git-ignored local
  override. Pre-commit runs a scoped `phpstan` hook (`pass_filenames: true`,
  `files: \.php$`) on staged `.php` files; pre-push runs `phpstan-full` over the
  whole tree.
- ema is installed as a Composer dependency (`judijasa/ema: dev-main`,
  unpinned); its `Ema\Config\*` PSR-4 mapping landed in ema `72ccdcd`, so
  `composer update` here is enough to make the classes resolvable.
- `bin/gen-grants` (`package_dependencies()`) and `bin/gen-service-accounts`
  (`package_vars()`, `package_declaration()`) `include` a package's
  `default.php` and read the variables it assigns — a `return` value is never
  seen.

## Changes

### php_daas_framework (this repo)

- [x] `pkg/roles-D04KGFJ8K9F5TFR2/`, `pkg/test.roles-D0JBP3672U3UJFIP/` — relocated from `srv/` (they carry no `$db`; `srv/` now requires a `DatabaseConfig`), which is what makes them representable as `PackageConfig`.
- [x] `bin/gen-grants`, `bin/gen-service-accounts` — locator root `srv/` → `pkg/`: `srv_package_dir()` → `pkg_package_dir()`, the `glob()` pattern, the error strings and the help text.
- [x] `doc/system/team-db-users.md`, `doc/system/service-accounts.md` — the roles-package paths (`srv/roles-<GUID>` → `pkg/roles-<GUID>`, `srv/<db>.roles-<GUID>` → `pkg/<db>.roles-<GUID>`, the roster glob, the "role definitions live in" paragraph).
- [x] all 6 `default.php` files — migrate to the class-returning form: `return new Ema\Config\DatabaseConfig(...)` for `srv/test-D0PR2OGMHXDSCAR3`, `PackageConfig(...)` for the five `pkg/` manifests, and the shared roles package's declaration as a nested `RolesConfig`.
- [x] `bin/gen-grants`, `bin/gen-service-accounts` — read the returned config object instead of the included file's variables; a migrated `default.php` otherwise yields no dependencies and no account declaration, silently.
- [x] `phpstan.dist.neon` — resolve `Ema\Config\*` via Composer autoload (run `composer update` to pick up ema's new PSR-4 mapping) and confirm the `default.php` files are covered.
- [x] `.pre-commit-config.yaml` — confirm the scoped `phpstan` hook passes staged `default.php` filenames (it already matches `\.php$`).
- [x] `doc/system/service-accounts.md` — the declaration reads as the nested `RolesConfig` (`sources`/`accounts`/`allowlist`), not the flat `$sources`/`$accounts`/`$allowlist` variables, and the absent-declaration behaviour matches the CLI (reports nothing to reconcile, exits non-zero).
- [x] `doc/system/ema.md`, `doc/system/replica-bootstrap.md` — the `$db[...]` key spellings become `DatabaseConfig` named arguments (`type: 'replica'`, `replica_of: '<primary>'`, `replica_ssl_verify_server_cert: true`); `$allowlist` reads as `allowlist`.
- [x] `doc/system/team-db-users.md` — the grant package's `$dependencies` reads as the `PackageConfig` field `dependencies`.

## Open items

- **Db-less `srv/` packages** — resolved: the roles/grants packages moved to
  `pkg/`, ema's manifest root. `srv/` holds database definitions only, so
  every `srv/` file can return a `DatabaseConfig`, and the roles declaration
  rides on `PackageConfig`'s `RolesConfig` as designed.
- **`{{dbname}}` is not an ema concept** — the relocated roles packages keep
  their placeholder SQL; the substitution stays in `gen-grants` /
  `gen-service-accounts`. A roles package must therefore never enter an ema
  dependency graph — no `srv/` database may list one in `$dependencies`, or
  ema would apply the literal `{{dbname}}`. None does today.
- **Element shapes** (`$sources`/`$accounts`/`$allowlist`) stay loosely typed
  (`array`) in `Ema\Config\RolesConfig` until this repo needs more.
- **Transition window** — resolved: ema has no dual shape. A legacy `$db` array
  is a hard error (`must return an \Ema\Config\DatabaseConfig`), so the migrated
  files flip in a single change set.
- **Timing** — resolved: `Ema\Config\*` and the PSR-4 mapping landed in ema
  `72ccdcd` (pushed to `main`), so this repo can `composer update` and start.
- **`bin/` is outside PHPStan's reach** — the CLIs are extensionless
  (`#!/usr/bin/env php`), so `phpstan.dist.neon`'s `paths: .` never picks them
  up (the full-tree run is clean while `phpstan analyse bin/gen-service-accounts`
  alone reports errors) and the pre-commit hook's `files: \.php$` never matches
  one. They are analyzed only when named explicitly, so this migration's edits
  to them carry no static gate. Folding them in is deferred.
- **`apply_sql` name collision** — `bin/gen-grants` and
  `bin/gen-service-accounts` each declare a global `apply_sql`, with three and
  four parameters respectively. Harmless as they stand (separate CLI processes;
  neither ever `require`s the other), but one PHPStan run over both resolves the
  four-argument calls against the three-parameter declaration and reports eight
  false errors. Each file analyzes clean on its own; renaming is deferred.
