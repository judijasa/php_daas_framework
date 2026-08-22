# Multi-server deploy with ZeroTier — Plan & Progress

## Decision

`deploy` targets **all prod servers** declared in a single machine registry
(`etc/machines.ini`) instead of one host passed on the command line. The
project database lives on **one** of those servers; the others deploy the
codebase only (no MariaDB instance). ZeroTier is the overlay network for every
prod connection — SSH for deploys and TCP for database access — so a prod
server without the database can serve the website against the database host.

## Topology

- Every dev + prod machine is on one ZeroTier network; the ZeroTier IP is the
  single address used for both `ssh` and the database connection.
- `[prod]` in `etc/machines.ini` lists each prod deploy target by its ZeroTier
  IP. Exactly one entry carries a non-empty value: `ip = dbname` marks the DB
  host and names the database. App-only servers have an empty value.
- The DB host listens on TCP (`DEPLOY_DB_PORT`), bound to the ZeroTier
  interface, so app-only servers and dev machines reach it over ZeroTier.
  `etc/reuter.ini`'s `[prod]` `SERVER` is the DB host's ZeroTier IP.
- dev → prod (DB + SSH) is the primary path; prod → prod DB is required;
  dev → dev and prod → prod SSH are out of scope (low priority).

## Config model

| File | Committed | Purpose |
|---|---|---|
| `etc/machines.ini` | no (git-ignored; template committed) | `[dev]` hostname→dbuser, `[prod]` ZeroTier-IP→dbname roster |
| `etc/deploy.conf` | yes | common deploy config for all prod hosts; `DEPLOY_DB_*` apply only on the DB host |
| `etc/env.prod` | yes | uniform runtime template (no `MYSQL_*`; TCP everywhere) |
| `etc/reuter.ini` | no (git-ignored) | connectivity contract; `[prod]` SERVER/PORT/DBNAME refreshed by `gen-reuter` |

## Changes

### Framework (`php_daas_framework`)

- [x] `etc/machines.ini.template` (new; replaces `etc/dev-machines.ini.template`).
- [x] `bin/gen-reuter` (new): writes `[prod]` SERVER/PORT/DBNAME into a
      reuter.ini from `etc/machines.ini` + `etc/deploy.conf`, preserving
      credentials and other sections.
- [x] `bin/deploy`: no positional host → deploy to every `[prod]` host;
      `deploy <host>` → that host only. Passes `DEPLOY_PROVISION_DB=1` and
      `DEPLOY_DB_BIND` to the DB host's provisioning.
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

- [x] Docs only: `ema` already reads `etc/reuter.ini [prod]` and connects over
      TCP for non-local targets, so no code change is needed.

## Open items

- Actual ZeroTier IPs/ports are machine data — filled into each repo's
  git-ignored `etc/machines.ini` / `etc/deploy.conf`, not committed.
- DB host firewall must allow the ZeroTier interface to `DEPLOY_DB_PORT`.
