# dev.conf default + validated override — Plan & Progress

Date: 2026-10-01
Repos: php_daas_framework (this repo); ema (upstream)

## Decision

`etc/dev.conf` gets a committed **default** (`etc/dev.default.conf`, tracked)
plus an optional git-ignored **override** (`etc/dev.conf`).
`bin/dev/init-local-env.sh` sources the default then the override and relays the
result into `.env`, so a quick setup needs no copy step.

The keys keep shell `export` shape. Resolution by key state:

- **absent** → default from `dev.default.conf` (ultimately the mechanism's
  `$USER` fallback for `DBUSER`);
- **empty** → key-specific: `SSL_DIR=` means "no client cert" (meaningful),
  `DBUSER=` is malformed (loud error);
- **present non-empty** → `SSL_DIR` must be an absolute path after shell
  expansion (loud error otherwise — a quoted `~` now fails loudly instead of
  silently); `DBUSER` is used as-is (semantic wrongness is the DB's to catch).

This repo also ships its own standalone `ema.default.conf` (it consumes ema),
mirroring ema's reader change.

## Changes

### php_daas_framework (this repo)

- [x] `bin/dev/init-local-env.sh` — source `etc/dev.default.conf` then
      `etc/dev.conf` (override, only if present); validate `DBUSER` (empty →
      error) and `SSL_DIR` (empty → omit; non-empty → absolute after expansion,
      error otherwise); relay into `.env`.
- [x] `etc/dev.conf.template` → `etc/dev.default.conf` — generic default
      (`DBUSER` documented as "unset → `$USER`", `SSL_DIR` commented = no cert),
      documenting the three-state rule.
- [x] `etc/ema.conf.template` → `etc/ema.default.conf` — standalone default for
      this repo's own `ema` use (documented, no `ssl-ca` by default).
- [x] (doc) — `doc/system/consumer-config.md`, `doc/system/machine-certs.md`,
      `doc/system/ema.md`, `README.md` document the default/override/validation
      model.

## Open items

- **`DBUSER` default location** — `$USER` stays a mechanism fallback (derived),
  documented in the default file rather than set by it.
- **Deploy override list** — consumers list only files they still override in
  `DEPLOY_PRIVATE_FILES`; `reuter.ini` remains a required private file.
- **Tolerant private-file shipping** — `bin/pf-deploy.sh` still fails on an
  absent listed file; revisit only if a consumer lists an optional override that
  may be absent (today they list `reuter.ini`).
