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
an auto-picked TCP port, started under the framework-installed
`mariadb@<instance>` systemd unit) before creating the database and applying
its schema packages in dependency order. The `mariadb@.service` unit itself is
a static file installed by `pf-provision.sh`, not authored by ema — ema asserts
it exists before provisioning. It does **not** create users or grants — the
service accounts and their per-object grants are consumer policy, owned by the
consumer's own provisioning.

## Command surface

- `ema sandbox srv/<name>-<GUID>` — build a per-instance dev sandbox under
  `var/sandbox/<name>-<guid>/` (bootstrap SQL + schema deps, in topological
  order), then open a shell; `-n/--no-shell` prints the connect command
  instead.
- `ema sandbox pkg/<pkg>-<GUID>` — synthesized default database (no bootstrap
  SQL) plus that package's dependency graph.
- `ema create srv/<name>-<GUID>` — always on prod (one-sided: it does not read
  `EMA_TARGET`): provision the per-database instance (when absent) and create
  the database + apply its dependencies. It is **create-only**: it refuses
  when the database already exists. On success it prints the `[<dbname>]`
  connectivity values (`SERVER`/`PORT`/`MYSQL_UNIX_PORT`/dbname) to record in
  the manual reuter.ini. `--dry-run` prints the SQL without applying. A
  `type=replica` package (`$db['type']='replica'` + `$db['replica_of']=<primary>`)
  instead takes `--from-snapshot <path>`: ema restores the shipped snapshot
  and attaches replication (no schema apply); see
  `doc/system/replica-bootstrap.md`.
- `ema values <db>` — print the same connectivity values for an existing
  database (recovery when the record is lost). Prod-side as well: no flag.
- `ema mariadb <db> < file.sql` — apply raw SQL over stdin as the section's
  client user. There is no `apply` verb (it is rejected). This is ema's only
  **dbname-addressed** verb, so it is the only one that consults `EMA_TARGET`
  (see below).
- `ema start|stop|restart|gc [<path>]` — sandbox-only lifecycle, addressed by
  instance **path** (`var/sandbox/<name>-<guid>`), never by name: a bare name
  or `srv/<key>` is refused with a hint to copy the path from `ema status`.
  `gc` removes stopped instance(s) — with a path, that one only, with no
  argument the whole sweep. Sandbox deletion is the whole
  `var/sandbox/<name>-<guid>/` directory; sandboxes are create-only, so a
  rebuild is `ema gc var/sandbox/<name>-<guid>` followed by
  `ema sandbox <target>`.
- `ema status` — the discovery surface: two labelled tables (sandbox
  instances, prod sections) with state, endpoint, age and the instance
  **path** as the trailing column (for prod, `$EMA_PROD_BASE/<db>` — default
  `/var/lib/mariadb/<db>` — when it exists on the host, `-` otherwise). Those
  printed paths are what the lifecycle verbs take.
- `ema drop` is retired: deleting a prod database is a deliberate
  `DROP DATABASE` over `ema mariadb`.

The old `ema init db <name>` / `ema init tables <root> <db>` verbs no longer
exist.

## EMA_TARGET

`EMA_TARGET` is a binary sandbox/prod **mode** flag — not a path or
connection-file selector. Both sides read the same variable, but each consults
it narrowly:

- the app layer (`Utils\Connectivity\Database`) dispatches on it for every
  connection it opens;
- the `ema` CLI consults it only for its one **dbname-addressed** verb,
  `ema mariadb <db>`: a database name alone is ambiguous (the same name exists
  on both sides), which is exactly what lets the app layer point at a sandbox
  without changing dbname or user. Everything else resolves its own side —
  `ema sandbox` loads its instance's ini, `create`/`values` always act on prod,
  and `start`/`stop`/`restart`/`gc` act on `var/sandbox/` by construction; when
  those are addressed by path, the side falls out of the path.

The values:

- `sandbox` — per-instance sandbox: the app layer resolves a database name to
  its `var/sandbox/<dbname>-<GUID>/reuter.ini` instance (exactly one match,
  otherwise an error naming the full `<name>-<GUID>` form), connecting as
  `root` over that instance's `MYSQL_UNIX_PORT` with an empty password — the
  same root/socket auth ema applies its DDL with. A sandbox has no
  credentials, so an agent's `dbAccount` is ignored; `ema mariadb <db>`
  likewise connects as `root` over the sandbox instance;
- `prod` — prod target via `$REUTER_INI` (fallback `etc/reuter.ini`), with the
  app layer on the service-account path (`connectAs` over TCP) and
  `ema mariadb <db>` connecting as `DBUSER`/`$USER`.

Any other value is an error. The connection-file path stays a separate env
var (`REUTER_INI`); `EMA_TARGET` only picks the mode. The old `EMA_MODE` is
gone. `Database::connectTo` treats unset/empty as `prod` (the app layer's
behavior before this flag existed), and ema's `_target()` uses the same
default, so a missing flag never means different things on the two sides.

Prod machines run `prod` mode **only because** the deploy chain writes
`EMA_TARGET=prod` and `REUTER_INI=$DEPLOY_REUTER_INI` (the consumer's manual
reuter.ini path) into the deployed `.env` (gen-env). ema never reads `.env`
itself, so the session that runs it must have those values in scope
(e.g. `set -a; . .env`, or a `tmux-remote` shell — see
`doc/system/tmux-remote.md`). The dev `.env` (init-local-env.sh) writes
`EMA_TARGET=sandbox` and no `REUTER_INI`: `phprun` sources that `.env` before
running an agent, which is how the app layer picks up the mode — and the dev
shell (`pf-shell-enter.sh`) sources it too, which is how `ema mariadb <db>`
picks the sandbox instance there. The lifecycle verbs need neither the flag
nor the `.env`.

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
    <ACCOUNT>_PASSWORD=...
    MYSQL_UNIX_PORT=/path/to/mysql.sock

ema's connectivity is read from the section: it connects via
`--socket=$MYSQL_UNIX_PORT` when the key is present, otherwise
`-h $SERVER -P $PORT` (TCP). The `<ACCOUNT>_PASSWORD` keys are consumer-side:
read by `Database::connectTo($dbname, $account)` on its prod path and written
by the consumer's own service-user provisioning; ema itself does not read
them.

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
- `pf-deploy.sh` ships the private files the consumer names in
  `DEPLOY_PRIVATE_FILES` into the freshly swapped `etc/` right after the repo
  swap + `composer install` and before anything reads them (the swap wipes
  `etc/`). `etc/deploy.conf` is never shipped: its values are replayed as
  environment to every remote step.
- `pf-deploy.sh`'s built-in server steps (run after provisioning and
  `DEPLOY_INIT_CMD`, as root, on every host):
  1. `gen-env` → `.env` with `EMA_TARGET=prod` and
     `REUTER_INI=$DEPLOY_REUTER_INI`;
  2. `db-check` → warn-only verification (never repairs): enumerates the
     host's own `mariadb@*` units (unit active, socket pings, schema exists)
     and TCP-checks each reuter.ini section;
  3. on every host: `cron-manifest --host-tags <host's tokens>` → `CRON_FILE`,
     restart cron (scope-filtered; `host`-scoped jobs run everywhere).
- `vendor/bin/pf-provision.sh` (`pf-deploy.sh`, root) asserts the `PROD_USER`
  account, creates the permanent system dirs, and installs the framework-owned
  `mariadb@.service` template unit. It never creates databases or users —
  instances are provisioned by `ema create` (which asserts the unit exists and
  starts `mariadb@<db>`).
- Consumer repos git-ignore `/var/`, `/etc/reuter.ini`, `/etc/machines.ini`,
  and `.env` (reuter.ini/machines.ini are consumer-owned private data).

## Creating databases on prod

`ema create srv/<name>-<GUID>` provisions the database's own MariaDB instance
(datadir, `/etc/<db>/my.cnf`, auto-picked TCP port, started under the
framework-installed `mariadb@<db>` systemd unit), creates the database, applies
its schema packages, then prints the `[<dbname>]` connectivity values
(`SERVER`/`PORT`/`MYSQL_UNIX_PORT`/dbname) for the operator to record in the
manual reuter.ini. The unit is installed by deploy (`pf-provision.sh`), so run
a deploy before the first `ema create`. The session must be on the DB host with
the deployed `.env` in scope — exactly the shell `tmux-remote` opens from the
repo root (it `cd`s to `DEPLOY_TARGET_DIR`, sources `.env` under `set -a`, and
puts `vendor/bin` first on `PATH`; see `doc/system/tmux-remote.md`):

    tmux-remote <db-host> <session>      # from the repo root
    ema create srv/<name>-<GUID>         # inside the session

`ema create` refuses when the database already exists. After creation, record
the printed section in the consumer's manual reuter.ini and provision the
service accounts with the consumer's own provisioning step (run on the DB host
as root over the socket), which is not shipped by this framework. `ema values
<db>` prints the same section later if the record is lost.

## Notes / open items

- The flag's reach is deliberately narrow: `EMA_TARGET` picks a side for
  **name-addressed** lookups only. The two namespaces are
  `var/sandbox/<name>-<GUID>` for sandboxes and `$EMA_PROD_BASE/<db>` (default
  `/var/lib/mariadb/<db>`) for prod instances — the paths `ema status` prints
  and the lifecycle verbs take.
- The sandbox path needs no consumer-side service-user provisioning: the app
  layer reaches an instance as `root` over its own socket, and the sandbox
  ini carries endpoint keys only (no passwords).
- Prod `connectAs` keeps reading `MYSQL_UNIX_PORT` from `.env` rather than
  from the section, so prod stays TCP-only; a socket-based prod transport is
  not wired.
