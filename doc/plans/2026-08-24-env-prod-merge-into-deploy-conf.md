# Merge etc/env.prod into etc/deploy.conf — proposal

Date: 2026-08-24
Repos: php_daas_framework (framework) + consumers (simox)
Status: proposal — not implemented

## Problem

`etc/env.prod` is a committed template that `gen-env` copies verbatim into the
git-ignored `.env` on every deploy. It overlaps `etc/deploy.conf` and can
drift:

- `REPO_PATH`  == `DEPLOY_TARGET_DIR`
- `REPO_LOG`   == `DEPLOY_LOG_DIR`
- `REUTER_INI` = `/etc/<app>/reuter.ini` (a function of the app/instance name)
- `EMA_TARGET` = `prod` (constant)

The dev side already *derives* `.env` at runtime (`init-local-env.sh`) instead
of storing a parallel file; prod is the odd one out.

## Proposal

Delete `etc/env.prod` (the framework `etc/env.prod.template` and the consumer
committed `etc/env.prod`) and turn `gen-env` into a small deterministic
projection of `etc/deploy.conf` → `.env`:

    REPO_PATH        := DEPLOY_TARGET_DIR
    REPO_LOG         := DEPLOY_LOG_DIR
    REUTER_INI       := /etc/<DEPLOY_DB_INSTANCE>/reuter.ini
    EMA_TARGET       := prod                       (constant)
    MYSQL_DATA_DIR   := DEPLOY_DB_BASE/data        (only on the DB host)
    MYSQL_UNIX_PORT  := DEPLOY_DB_BASE/mysql.sock  (only on the DB host)
    MYSQL_PID_FILE   := DEPLOY_DB_BASE/mysql.pid   (only on the DB host)

Notes:

- **App-only-host guard:** emit `MYSQL_*` only when `$DEPLOY_DB_BASE/mysql.sock`
  exists on the host (socket existence == "this is the DB host"). Emitting them
  unconditionally would make app-only servers append `;unix_socket=...` to
  their TCP DSN (`Database.php` does this whenever `MYSQL_UNIX_PORT` is set)
  and break ZeroTier connections to the DB host.
- **REUTER_INI app name:** use `DEPLOY_DB_INSTANCE` (the config-dir name,
  `/etc/<instance>/my.cnf`), not `PROD_USER` — `PROD_USER` is documented as
  "deliberately NOT the repo name" and can diverge.
- **DEPLOY_DB_INSTANCE default:** when unset it defaults to the basename of
  `DEPLOY_TARGET_DIR` (the existing `etc/deploy.conf` contract).

## Relationship to the reuter.ini redesign

Orthogonal to the section model tracked in
ema/doc/2026-08-22-reuter-redesign.md. The `MYSQL_*` projection above only
matters if that doc's issue 7 is resolved via `.env` (option A); if resolved
via the `reuter.ini` section (option B), `.env` stays `MYSQL_*`-free and this
projection emits only the four base keys.

## Files (when implemented)

- framework `bin/gen-env` — projection + fail-fast on required `deploy.conf`
  keys + fixture tests (DB host vs app-only host).
- delete framework `etc/env.prod.template`; delete consumer committed
  `etc/env.prod` (simox).
- `etc/deploy.conf.template` — note that `gen-env` derives `.env` from it.
- docs: framework README, simox README + `2026-08-14-deploy-relocation.md` /
  `2026-08-17-env-relocation.md` (they reference `etc/env.prod`).
