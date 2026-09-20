# ema — integration with php_daas_framework

Date: 2026-09-07
Scope: how the `ema` CLI (MariaDB schema manager) plugs into this framework's
connectivity and deploy model.

## What ema is

`ema` is a Bash CLI that manages MariaDB databases from a repo's `pkg/`
(schema packages) and `srv/` (per-database packages `srv/<name>-<GUID>/`,
each a `default.php` + `upgrade.sql` pair). It ships as its own Composer
package (`judijasa/ema`), installed under `vendor/judijasa/ema` with
`vendor/bin/ema` and `vendor/bin/init-cluster.sh` on the PATH — the same
remote `composer install` that delivers the framework's own CLIs
(`gen-env`, `db-check`, ...) to `vendor/bin`.

ema provisions **the instance and the schema**: `ema create` provisions a
dedicated MariaDB instance per database (datadir, `/etc/<instance>/my.cnf`,
`mariadb@<instance>` systemd unit, an auto-picked TCP port) before creating
the database and applying its schema packages in dependency order. It does
**not** create users or grants — the service accounts and their per-object
grants are consumer policy, owned by the consumer's own provisioning.

## Command surface

- `ema sandbox srv/<name>-<GUID>` — build a per-instance dev sandbox under
  `var/sandbox/<name>-<guid>/` (bootstrap SQL + schema deps, in topological
  order), then open a shell; `-n/--no-shell` prints the connect command
  instead.
- `ema sandbox pkg/<pkg>-<GUID>` — synthesized default database (no bootstrap
  SQL) plus that package's dependency graph.
- `ema create srv/<name>-<GUID>` — prod-only (requires `EMA_TARGET=prod`):
  provision the per-database instance (when absent) and create the database
  + apply its dependencies. It is **create-only**: it refuses when the
  database already exists. On success it prints the `[<dbname>]` connectivity
  values (`SERVER`/`PORT`/`MYSQL_UNIX_PORT`/dbname) to record in the manual
  reuter.ini. `--dry-run` prints the SQL without applying. A `type=replica`
  package (`$db['type']='replica'` + `$db['replica_of']=<primary>`) instead
  takes `--from-snapshot <path>`: ema restores the shipped snapshot and
  attaches replication (no schema apply); see
  `doc/system/replica-bootstrap.md`.
- `ema values <db>` — print the same connectivity values for an existing
  database (recovery when the record is lost).
- `ema mariadb <db> < file.sql` — apply raw SQL over stdin as the section's
  client user. There is no `apply` verb (it is rejected).
- `ema drop/start/stop/restart/status/gc` — instance lifecycle. Sandbox
  deletion is the whole `var/sandbox/<name>-<guid>/` directory.

The old `ema init db <name>` / `ema init tables <root> <db>` verbs no longer
exist.

## EMA_TARGET

`EMA_TARGET` is a binary operation-mode flag, not a path selector:

- unset or `sandbox` (default) — per-instance sandbox (`ema sandbox ...`);
- `prod` — prod target via `$REUTER_INI` (fallback `etc/reuter.ini`).

Any other value is an error. The connection-file path stays a separate env
var (`REUTER_INI`); `EMA_TARGET` only picks the mode. The old `EMA_MODE` is
gone.

Prod machines run `prod` mode **only because** the deploy chain writes
`EMA_TARGET=prod` and `REUTER_INI=$DEPLOY_REUTER_INI` (the consumer's manual
reuter.ini path) into the deployed `.env` (gen-env). ema never reads `.env`
itself, so the session that runs it must have those values in scope
(e.g. `set -a; . .env`).

## The reuter.ini contract

`etc/reuter.ini` is **manual, consumer-owned** private data — there is no
generator anymore. `ema create` prints the `[<dbname>]` section and the
operator records it (or `ema values <db>` recovers a lost record); the
consumer owns the file (it keeps it in its private config repo and places it
in `etc/` — see `doc/system/consumer-config.md`). Sections are keyed by
database name — the
section header IS the dbname:

    [mydb]
    SERVER=10.147.x.x
    PORT=3306
    DBMS=mariadb
    <ACCOUNT>_PASSWORD=...
    MYSQL_UNIX_PORT=/path/to/mysql.sock

ema's connectivity is read from the section: it connects via
`--socket=$MYSQL_UNIX_PORT` when the key is present, otherwise
`-h $SERVER -P $PORT` (TCP). The `<ACCOUNT>_PASSWORD` keys are consumer-side:
read by `Database::connectAs($dbname, $account)` and written by the consumer's
own service-user provisioning; ema itself does not read them.

## Service accounts are consumer policy

`upgrade.sql` carries DDL only, filled from `{{dbname}}`/`{{charset}}`/
`{{collation}}` (no user/grants placeholders). The service accounts and their
grants are consumer policy: the consumer provisions them separately (on the DB
host as root over the socket) and persists one `<ACCOUNT>_PASSWORD` key per
account into the section (an empty value means a passwordless account).
Per-object grants live in the consumer's `pkg/<name>-<GUID>/upgrade.sql`,
applied by ema.

## reuter.ini is manual (no generator)

The prod `reuter.ini` is a **manually-maintained, consumer-owned** file: there
is no `gen-reuter` and no `DEPLOY_DB_*` deploy config. The operator records
the `[<dbname>]` section that `ema create` prints on success (or recovers it
with `ema values <db>`), then commits/injects it as private data. A missing
section on prod is a misconfiguration — `db-check` warns on it but does not
repair. `gen-env` only projects the file's *path* (`DEPLOY_REUTER_INI`) into
`.env` as `REUTER_INI`; the section contents are never generated.

## Deploy chain

- `pf-deploy.sh` ships `pkg/` and `srv/` (gitattributes keeps them in the
  archive), then runs `composer install` on the remote so the framework CLIs
  (`gen-env`, `db-check`, `pf-provision.sh`, ...) and `ema` land in
  `vendor/bin`.
- `pf-deploy.sh` runs the consumer's optional `DEPLOY_PRE_PROVISION_CMD` on the
  host right after the repo swap + `composer install` and before provisioning:
  it restores the real private config the swap wiped (at least
  `etc/deploy.conf` and `etc/reuter.ini`), with the deploy machine's
  `deploy.conf` environment replayed.
- `pf-deploy.sh`'s built-in server steps (run after provisioning and
  `DEPLOY_INIT_CMD`, as root, on every host):
  1. `gen-env` → `.env` with `EMA_TARGET=prod` and
     `REUTER_INI=$DEPLOY_REUTER_INI`;
  2. `db-check` → warn-only verification (never repairs): enumerates the
     host's own `mariadb@*` units (unit active, socket pings, schema exists)
     and TCP-checks each reuter.ini section;
  3. on `worker`-tagged hosts: `cron-manifest` → `CRON_FILE`, restart cron.
- `vendor/bin/pf-provision.sh` (`pf-deploy.sh`, root) asserts the `PROD_USER`
  account and creates the permanent system dirs. It never provisions MariaDB
  and never creates databases or users — instances are owned by `ema create`.
- Consumer repos git-ignore `/var/`, `/etc/reuter.ini`, `/etc/machines.ini`,
  and `.env` (reuter.ini/machines.ini are consumer-owned private data).

## Creating databases on prod

`ema create srv/<name>-<GUID>` provisions the database's own MariaDB instance
(datadir, `/etc/<db>/my.cnf`, `mariadb@<db>` systemd unit, auto-picked TCP
port), creates the database, applies its schema packages, then prints the
`[<dbname>]` connectivity values (`SERVER`/`PORT`/`MYSQL_UNIX_PORT`/dbname)
for the operator to record in the manual reuter.ini. The deployed `.env` must
be in scope for the session:

    ssh root@<db-host> 'cd <deploy-dir> && set -a && . .env && ema create srv/<name>-<GUID>'

`ema create` refuses when the database already exists. After creation, record
the printed section in the consumer's manual reuter.ini and provision the
service accounts with the consumer's own provisioning step (run on the DB host
as root over the socket), which is not shipped by this framework. `ema values
<db>` prints the same section later if the record is lost.

## Notes / open items

- Dev app-layer resolution is still being wired: the dev sandbox writes its
  own `var/sandbox/<name>-<guid>/reuter.ini` (endpoint keys only, no
  passwords), while the framework's `Database` class reads the
  `<ACCOUNT>_PASSWORD` key from the resolved section. Pointing dev
  `REUTER_INI` at the sandbox file and applying the consumer's service-user
  provisioning there is the pending piece.
- `Database.php` resolves sections by dbname alone and does not read
  `EMA_TARGET`.
