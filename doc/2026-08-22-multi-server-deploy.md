# Multi-server deploy with ZeroTier — Plan & Progress

## Decision

`deploy` targets **all prod servers** declared in a single machine registry
(`etc/machines.ini`) instead of one host passed on the command line. Databases
live on the prod servers that declare them; the rest deploy the codebase only
(no MariaDB instance). A project may map several databases, on one server or
across servers. ZeroTier is the overlay network for every prod connection —
SSH for deploys and TCP for database access — so a prod server without a
database can serve the website against the database host.

## Topology

- Every dev + prod machine is on one ZeroTier network; the ZeroTier IP is the
  single address used for both `ssh` and the database connection.
- `[prod]` in `etc/machines.ini` lists each prod deploy target by its ZeroTier
  IP; the value is a comma-separated list of database names that server hosts
  (empty = app-only). **Constraint: each database is hosted by exactly one
  server** (a database may not span servers). A server may host no database
  (app-only), one database, or several databases in its MariaDB instance
  (per project).
- A database host listens on TCP (`DEPLOY_DB_PORT`), bound to the ZeroTier
  interface, so app-only servers and dev machines reach it over ZeroTier.
  `etc/reuter.ini` carries one section per database — `[<dbname>]` (prod,
  `SERVER` = the hosting server's ZeroTier IP) and `[local:<dbname>]` /
  `[local]` (dev sandbox) — refreshed by `gen-reuter` for the prod sections.
- dev → prod (DB + SSH) is the primary path; prod → prod DB is required;
  dev → dev and prod → prod SSH are out of scope (low priority).

## Config model

| File | Committed | Purpose |
|---|---|---|
| `etc/machines.ini` | no (git-ignored; template committed) | `[dev]` hostname→dbuser, `[prod]` ZeroTier-IP→database-names roster |
| `etc/deploy.conf` | yes | common deploy config for all prod hosts; `DEPLOY_DB_*` apply only on the DB host |
| `etc/env.prod` | yes | uniform runtime template (no `MYSQL_*`; TCP everywhere) |
| `etc/reuter.ini` | no (git-ignored) | connectivity contract; one `[<dbname>]` section per prod database refreshed by `gen-reuter`, plus `[local]`/`[local:<dbname>]` for dev |

## Changes

### Framework (`php_daas_framework`)

- [x] `etc/machines.ini.template` (new; replaces `etc/dev-machines.ini.template`).
- [x] `bin/gen-reuter` (new): writes one `[<dbname>]` section per prod
      database (SERVER/PORT/DBNAME) from `etc/machines.ini` +
      `etc/deploy.conf`, enforcing that each database is hosted by exactly one server,
      preserving credentials and the `[local]`/`[local:<dbname>]` dev
      sections.
- [x] `bin/deploy`: no positional host → deploy to every `[prod]` host;
      `deploy <host>` → that host only. Any host with a non-empty database
      list is a database host (one MariaDB instance serves all its
      databases). Enforces that each database is hosted by exactly one server. Passes
      `DEPLOY_PROVISION_DB=1` and `DEPLOY_DB_BIND` to DB-host provisioning.
- [x] `bin/provision.sh`: MariaDB block runs only when `DEPLOY_PROVISION_DB=1`;
      with `DEPLOY_DB_PORT` it writes `bind-address` instead of
      `skip-networking`.
- [x] `bin/dev/init-local-env.sh`: reads `[dev]` from `etc/machines.ini`; calls
      `gen-reuter` when available.
- [x] `.gitignore`: `/etc/dev-machines.ini` → `/etc/machines.ini`.
- [x] `flake.nix` + `composer.json`: ship `gen-reuter`.
- [x] `etc/deploy.conf.template`, `README.md`: document the new model.

### simox (`../simox`)

- [x] `etc/machines.ini` (+ template): migrate `dev-machines.ini` into `[dev]`,
      add `[prod]` ZeroTier roster.
- [x] `etc/deploy.conf`: add `DEPLOY_DB_PORT` / `DEPLOY_DB_BIND`.
- [x] `etc/env.prod`: drop `MYSQL_*` (TCP everywhere).
- [x] `bin/deploy/post-nix.sh`: call `gen-reuter "$REUTER_INI"`.
- [x] `.gitignore`, `README.md`.

### ema (`../ema`)

- [x] `ema` resolves reuter.ini sections by database name (`ema mariadb <db>`,
      `ema init db <db>`, `EMA_TARGET=<db> ema init tables <root>`); local
      prefers `[local:<dbname>]` with `[local]` fallback. README/example
      updated. Still transport-agnostic (ZeroTier only appears as `SERVER`).

## Open items

- Actual ZeroTier IPs/ports are machine data — filled into each repo's
  git-ignored `etc/machines.ini` / `etc/deploy.conf`, not committed.
- DB host firewall must allow the ZeroTier interface to `DEPLOY_DB_PORT`.
