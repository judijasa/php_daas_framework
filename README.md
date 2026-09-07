# php_daas_framework

A PHP framework for **data-as-a-service** agent projects.
It bundles a small application framework for scheduled,
database-backed data-processing agents:

- **`#[Agent]` / `#[CronJob]` attributes** — declare which functions are
  runnable agents and their schedules; consumed by `phprun`, the cron-manifest
  generator, and the pre-commit attribute check.
- **`phprun` CLI** — executes an `#[Agent]`-annotated function from any PHP
  file, injecting a DB connection when the agent declares a `dbTarget`,
  with cron-friendly logging.
- **`Utils\Connectivity\Database`** — PDO wrapper; `Database::connectAs($dbname,
  $account)` opens a connection for a consumer-named service account, reading
  its `<ACCOUNT>_PASSWORD` from the consumer's `reuter.ini` section.
- **`Utils\DatabaseOps`** — `CursorSeq`, `BatchInsert`, `BatchScan`: resumable
  batch processing with persisted cursors.
- **`Utils\Crawler\CasperTrio`**, **`Utils\Logger`** — casperjs subclass and a
  tiny timestamped logger.

```bash
phprun 'path/to/script.php:my_agent($arg=1)'
```

The runner:

1. Validates that the target function carries the `#[Agent]` attribute.
2. If the agent declares `dbTarget: 'dbname'` + `dbAccount: 'account'`, it opens
   a connection via `Utils\Connectivity\Database::connectAs($dbTarget, $dbAccount)`
   and injects it as the first argument of the call.
3. Eval-dispatches the function, logging start/finish timestamps to a per-script
   log file (see `REPO_LOG`).

## Expected consumer directory structure

The framework relies on a few conventions in the consuming project:

```
<consumer repo root>/
├── vendor/            # composer autoload; phprun requires vendor/autoload.php from here
├── etc/reuter.ini     # DB config (or set REUTER_INI to point elsewhere)
└── src/…              # agent scripts, referenced relative to the repo root
```

`phprun` must be invoked from the consumer repo root (or from cron, in which
case it cds there automatically via `REPO_PATH`).

## Standalone template usage

This repo is dual-role. It is a framework **consumed** by external projects,
and it is also a **standalone repo** meant to behave as much as possible like
one of its own consumers: every consumer workflow (`make dev-init`,
`bin/phprun`, `bin/pf-deploy.sh`, `gen-env`, `cron-manifest`) should work from
inside this repo exactly as it would in a consumer — only the config data is
this repo's own (`etc/deploy.conf`, `etc/reuter.ini`, ...). The one
structural difference vs. an external consumer: the framework does not
consume itself via its own `flake.nix` and `composer.json` (that would be
circular) — its Makefile and `bin/` scripts invoke the local copies, and
those same files are the artifacts external consumers pull in. The framework
owns the mechanism; the consumer (or this repo, standalone) owns the data
and policy.

The repo works as a **forkable template** — a plain PHP project you clone
and build on directly.

### Standalone dev init

1. Clone, enter the dev shell, and build the sandbox (creates `var/`,
   initializes/starts an isolated MariaDB, runs `composer install`, and
   writes the git-ignored `.env`):

   ```bash
   git clone <repo> php_daas_framework
   cd php_daas_framework
   nix develop
   make dev-init
   ```

2. Create the `test` database + dev sandbox (git-ignored, under
   `var/sandbox/`):

   ```bash
   ema sandbox srv/test-D0PR2OGMHXDSCAR3
   ```

   Optional: `cp etc/machines.ini.template etc/machines.ini` and fill in the
  [dev] hostname-to-dbuser mapping and the [prod] ZeroTier deploy roster
   this machine's hostname to a DB user — only needed for remote DB access.

3. Re-enter the shell (or `source .env`) so the shell sees the `MYSQL_*`
   paths. Write your agents under `src/scripts/` (see
   `src/scripts/demo/hello.php`) and run them from the repo root:

   ```bash
   bin/phprun 'src/scripts/demo/hello.php:hello()'
   ```

`phprun` loads `.env` from the current working directory (the repo root)
before doing anything else — no manual exports needed. `make dev-init`
writes `.env` with the repo paths, `REUTER_INI`, `EMA_TARGET=sandbox` and, when
`etc/machines.ini` `[dev]` maps the machine hostname to the prod DB username (`DBUSER`); `[prod]` lists the prod deploy targets (ZeroTier IP = comma-separated `tag[:name]` tokens; `db` is the built-in tag, other tags are consumer-owned; each named token maps to exactly one server).

In template mode the classes are autoloaded from the framework's **own**
`vendor/autoload.php`, and `etc/reuter.ini` is resolved from the repo root.
The same code base is consumed as a library by other projects (see below) —
both modes share the identical `Utils\` classes in `src/`.

### Standalone prod init

Deploying this repo to a production server runs the exact same `bin/pf-deploy.sh`
workflow as a consumer — only the config data is this repo's own. One
committed config file must exist before the first deploy:

1. **`etc/deploy.conf`** — copy from `etc/deploy.conf.template`, fill in the
   deployment target (`PROD_USER`, `DEPLOY_TARGET_DIR`, `DEPLOY_LOG_DIR`,
   `DEPLOY_DB_BASE`, `DEPLOY_NIX_RESULT_DIR`, `DEPLOY_NIX_GCROOT`), and
   commit. Optional: `DEPLOY_INIT_CMD` (consumer-specific provisioning
   command run after the framework's generic `bin/pf-provision.sh`) and cron
   vars (`CRON_FILE`, `CRON_USER`). `pf-deploy.sh` fails loudly if this file is
   missing. The remote host must already have the `PROD_USER` account with
   SSH access — see "Before the first deploy" under "Deploying a consumer
   project".

The git-ignored `.env` is generated on the remote on every deploy — there is
no committed `etc/env.prod` anymore: `gen-env` projects it deterministically
from `etc/deploy.conf` (`REPO_PATH` = `DEPLOY_TARGET_DIR`, `REPO_LOG` =
`DEPLOY_LOG_DIR`, `REUTER_INI` = `/etc/<DEPLOY_DB_INSTANCE>/reuter.ini`,
`EMA_TARGET = prod`; the `.env` stays `MYSQL_*`-free — the DB host's socket
lives in the prod `reuter.ini` sections (`gen-reuter`), not in `.env`).
`gen-env` fails loudly if a required `deploy.conf` key is missing or a
projected key is lost in the output.

The local `.env` (with `REPO_PATH`) comes from `make dev-init` — machine
settings, git-ignored. Then deploy from the repo root, inside `nix develop`,
on `main`, with a clean tree:

```bash
bin/pf-deploy.sh                 # continuous deployment to every [prod] host in etc/machines.ini
bin/pf-deploy.sh <target_host>   # deploy to a single prod host (must be in [prod])
bin/pf-deploy.sh --init          # + one-time provisioning (MariaDB only on the DB host)
```

`pf-deploy.sh` invokes no consumer hooks; consumer-specific post-deploy steps are
added by wrapping `vendor/bin/pf-deploy.sh` (see "Deploying a consumer project"
below).

## Quick test: PHP–MariaDB integration with ema

The dev shell bundles PHP (with `pdo_mysql`), MariaDB and composer.
[`ema`](https://github.com/judijasa/ema) — a MariaDB package manager — is
Composer-delivered (`vendor/bin/ema`).
`make dev-init` initializes and starts an isolated MariaDB on a
unix socket under `var/`, so there is no system DB to install.

```bash
nix develop
make dev-init    # dirs, MariaDB init+start, composer install, .env
source .env      # (or re-enter the shell) so the shell sees the MYSQL_* paths

# 1. Create the `test` database + dev sandbox (bootstrap + schema deps)
ema sandbox srv/test-D0PR2OGMHXDSCAR3

# 2. Run the integration agent
bin/phprun 'src/scripts/demo/db_smoke.php:main()'
```

What the agent exercises, end to end:

- **`Utils\Connectivity\Database`** — the runner injects `$conn`, a real PDO
  connection created by `Database::connectAs('test', 'demo')` using the `[test]`
  section of `var/sandbox/test-d0pr2ogmhxdscar3/reuter.ini` and the `MYSQL_UNIX_PORT` socket.
- **`Utils\DatabaseOps\BatchInsert`** — persists 10 demo rows into the `items`
  table in chunks of 5.
- **`Utils\DatabaseOps\CursorSeq`** — reads/initializes and advances a cursor
  persisted in the `cursorseq` table.
- **`Utils\DatabaseOps\BatchScan`** — reprocesses `items` in batches of 3,
  resuming from a persisted cursor.

Inspect the results interactively:

```bash
ema mariadb test
SELECT * FROM items;
SELECT * FROM cursorseq;
```

Re-running the agent is safe — `BatchScan` resumes from the cursor stored in
`cursorseq`. To reset the database, drop and rebuild the sandbox
(`ema drop srv/test-D0PR2OGMHXDSCAR3`, then `ema sandbox` again).

The building blocks behind the quick test live in the repo:

| Path | Purpose |
|---|---|
| `srv/test-*/` | database package (`default.php` + `upgrade.sql`) consumed by `ema sandbox srv/test-D0PR2OGMHXDSCAR3` |
| `pkg/cursorseq-*/` | `cursorseq` table (contract of `CursorSeq`/`BatchScan`) |
| `pkg/items-*/` | demo `items` table |
| `pkg/demo-*/` | root schema package listing the dependencies in order |
| `src/scripts/demo/db_smoke.php` | the agent exercising the DB layer |


## Distribution

The framework code is delivered by Composer only. The `composer.json` `bin`
array installs the CLIs and scripts into `vendor/bin`:

- `bin/phprun`, `bin/pf-deploy.sh`, `bin/pf-roster`, `bin/gen-env`,
  `bin/gen-reuter`, `bin/cron-manifest` — the framework CLIs.
- `bin/dev/pf-shell-enter.sh`, `bin/dev/init-local-env.sh` — the dev-init
  machinery.
- `bin/pf-provision.sh` — the generic production provisioning script, invoked
  by `pf-deploy.sh --init` as `vendor/bin/pf-provision.sh`.

The PHP library itself (the `Utils\` PSR-4 namespace under `src/`) is
autoloaded from `vendor/autoload.php`.

The `flake.nix` is dev-only: it declares the environment binaries (PHP with
the `mysqli`/`pdo_mysql`/`bz2` extensions, composer, MariaDB, bash, phpstan,
pre-commit) for the standalone dev shell. It no longer re-exports framework
code or the `ema` CLI — `ema` (`judijasa/ema`) is its own Composer package,
pinned independently.

### Dev-init machinery for consumers

The dev scripts are Composer-delivered (`vendor/bin`), so a consumer's own
`make dev-init` can delegate the generic steps to them:

```make
_dev-init-cluster:
        @vendor/bin/init-cluster.sh "$(MYSQL_DATA_DIR)" "$(MYSQL_PID_FILE)" "$(MYSQL_UNIX_PORT)"

_dev-init-local-env:
        @vendor/bin/init-local-env.sh
```

`init-local-env.sh [target-dir]` (default `$PWD`) writes the repo-root `.env`
(`REPO_PATH`, `REPO_LOG`, `MYSQL_*`, `REUTER_INI`, `EMA_TARGET=sandbox`, and
`DBUSER` when `etc/machines.ini` maps the hostname). `init-cluster.sh`
(the MariaDB cluster init: `mariadb-install-db` + start `mysqld`, taking
the data-dir/pid-file/socket as arguments) is **owned by ema** and shipped in
ema's own `composer.json` `bin` array (`vendor/bin/init-cluster.sh`) — this
framework reuses it rather than keeping a duplicate copy. Everything is
derived from the target directory at runtime — no consumer paths are baked
in. Consumer-specific steps (git hooks, hosts, ...) stay in the consumer's
Makefile, and the dev shell shellHook sources `pf-shell-enter.sh` (loads `.env`,
resumes the local MariaDB daemon): standalone flakes source
`./bin/dev/pf-shell-enter.sh`, consumers source `vendor/bin/pf-shell-enter.sh`.

## Environment variables

`phprun` loads its runtime configuration from a `.env` file in the current
working directory (the consumer repo root) before doing anything else. This
is the canonical way to configure a deployment: generate `.env` per
environment (e.g. `make dev-init` in dev, or at deploy time in prod) and
invoke `phprun` from the repo root. Values in `.env` override anything
already in the process environment; if neither provides the required
variables, `phprun` fails loudly. The dev `.env` is regenerated every time by
`make dev-init` (`init-local-env.sh`); the production `.env` is regenerated on
every deploy by `gen-env` as a deterministic projection of the committed
`etc/deploy.conf`.

| Variable | Purpose |
|---|---|
| `REPO_PATH` | Consumer repo root. `phprun` must be run from here (when invoked from cron it cds here automatically). |
| `REPO_LOG` | Directory where per-script logs are appended. |
| `REUTER_INI` | Path to the DB config ini consumed by `Utils\\Connectivity\\Database`; falls back to `$PWD/etc/reuter.ini`. |
| `EMA_TARGET` | Operation-mode flag for the `ema` CLI only (`sandbox` = local per-instance, `prod` = server). The app layer ignores it; a database is always resolved to its `[<dbname>]` section. |
| `MYSQL_UNIX_PORT` | Dev-only: unix socket appended to the DSN (set by `init-local-env.sh`). Prod `.env` stays `MYSQL_*`-free; the prod socket lives in the `reuter.ini` section (`gen-reuter`). |

## Deploying a consumer project

The repo also ships a `pf-deploy.sh` CLI (next to `phprun`) that pushes a consumer
repo to a remote production server: near-atomic swap of the repo dir, local
`nix build` + closure copy, `composer install` on every deploy (`git archive` wipes `vendor/` each time), and optional
one-time provisioning (`--init`).

Standalone, the same CLI deploys this repo itself — the required committed
config (`etc/deploy.conf`) and the exact steps are in "Standalone prod init"
under "Standalone template usage". The workflow is identical to a consumer's;
only the config data differs.

```bash
pf-deploy.sh               # continuous deployment to every [prod] host in etc/machines.ini
pf-deploy.sh <target_host> # deploy to a single prod host (must be in [prod])
pf-deploy.sh --init        # + one-time provisioning (MariaDB only on the DB host)
```

`pf-deploy.sh` reads three config surfaces from the consumer repo root:

- **`etc/deploy.conf`** (committed, required) - the project-static deployment
  target; copy from `etc/deploy.conf.template` and fill in:

| Variable | Purpose |
|---|---|
| `PROD_USER` | Unprivileged app user on the remote host. Short, deliberate name — not the repo name (e.g. `php_daas_framework` -> `daas`). Must exist with SSH access before the first deploy (see below). |
| `DEPLOY_TARGET_DIR` | Remote repo location (e.g. `/srv/apps/<app>`). |
| `DEPLOY_LOG_DIR` | Remote log dir (`deploy_version.log` lives here). |
| `DEPLOY_DB_BASE` | Remote root of the per-project MariaDB instance (DB host only); datadir/socket/pid-file are derived from it by convention (`data`, `mysql.sock`, `mysql.pid`), created and started by `pf-deploy.sh --init` (generic `bin/pf-provision.sh`) via a `mariadb@<instance>` systemd unit. |
| `DEPLOY_DB_INSTANCE` | Optional: systemd unit + config-dir name (`mariadb@<instance>`, `/etc/<instance>/my.cnf`); also the prod `reuter.ini` path (`/etc/<instance>/reuter.ini`) that `gen-env` writes into `.env` as `REUTER_INI`; defaults to the basename of `DEPLOY_TARGET_DIR`. |
| `DEPLOY_DB_PORT` | Required on the database host: TCP port the MariaDB instance listens on. Scripts on every prod server — the DB host and app-only hosts alike — connect to the database over TCP. |
| `DEPLOY_DB_BIND` | Optional: address the daemon binds to (default `0.0.0.0`); set it to the DB host's ZeroTier IP to restrict access to the overlay network. |
| `DEPLOY_NIX_RESULT_DIR` | Remote nix result parent (e.g. `/usr/local/<app>`). |
| `DEPLOY_NIX_GCROOT` | Remote nix gcroot (e.g. `/nix/var/nix/gcroots/<app>`). |
| `DEPLOY_INIT_CMD` | Optional: consumer-specific provisioning command run after the framework's generic `bin/pf-provision.sh` on `--init`. |
| `CRON_FILE` | Optional: remote crontab file the consumer's deploy wrapper installs the `cron-manifest` output into. |
| `CRON_USER` | Optional: user the cron entries run as (default `root`). |

- **`etc/machines.ini`** (git-ignored; template committed) - the machine
  registry: `[dev]` hostname→prod DB username, `[prod]` ZeroTier-IP→`tag[:name]`
  tokens (comma-separated per server; `db` is the built-in tag, other tags are
  consumer-owned). `pf-deploy.sh` (default mode) targets every `[prod]` host; a
  host carrying a `db:<name>` token is a database host and gets a MariaDB
  instance on `--init` (one instance serves all its `db:` names). Each named
  token maps to exactly one server; a server may host several databases. The
  shared `pf-roster` CLI parses this roster for `pf-deploy.sh`, `gen-reuter`
  and the consumer's deploy wrapper.
  Commit this file only in a private fork.

- **`.env`** (git-ignored, machine-specific) - same contract as `phprun`;
  pf-deploy.sh needs `REPO_PATH` (set by the consumer's dev-init).

`pf-deploy.sh` fails loudly if `etc/deploy.conf` or `etc/machines.ini` is missing.

`gen-reuter` (shipped alongside `pf-deploy.sh`) writes one reuter.ini section per
`db:<name>` token (`[<dbname>]` with SERVER/PORT/DBMS/MYSQL_UNIX_PORT) from
`etc/machines.ini` + `etc/deploy.conf`, preserving the credentials and dropping
any `[local]`/`[local:<dbname>]` dev sections (the dev sandbox lives in
`var/sandbox/<name>-<guid>/reuter.ini`, generated by `ema sandbox srv/<name>-<GUID>`)
— run it after changing the mapping (dev: `init-local-env.sh` runs it
automatically; prod: the consumer's deploy wrapper calls it with the
`REUTER_INI` path).

### Before the first deploy

The remote host must have the app user in place before the first `pf-deploy.sh`
(or `pf-deploy.sh --init`) — the CLI does not create it (assert-only):

1. **Create the app user** (`PROD_USER` from `etc/deploy.conf`) as root:

   ```bash
   useradd --create-home --shell /bin/bash --comment "Production app user" <PROD_USER>
   passwd --lock <PROD_USER>
   ```

   `--create-home` is required (the nix installation stores per-user state in
   `~<PROD_USER>`); `passwd --lock` disables password login, making the SSH
   key the only entry point.

2. **Install SSH access** for that user — the same public key used to log in
   as `root`:

   ```bash
   mkdir -p /home/<PROD_USER>/.ssh
   chmod 700 /home/<PROD_USER>/.ssh
   echo "<ssh-ed25519 AAAA... your-key>" >> /home/<PROD_USER>/.ssh/authorized_keys
   chmod 600 /home/<PROD_USER>/.ssh/authorized_keys
   chown -R <PROD_USER>:<PROD_USER> /home/<PROD_USER>/.ssh
   ```

   `pf-deploy.sh` SSHes into the server as both `root` and `<PROD_USER>` — the nix
   closure copy and `composer install` run as the app user. `pf-deploy.sh` fails
   loudly if the user does not exist, and those steps fail until the key is
   installed.

Everything else (repo swap, dirs, MariaDB cluster init) is handled by `pf-deploy.sh`
itself: the repo swap as `root`, and the one-time provisioning (`pf-deploy.sh --init`)
via the framework's generic `bin/pf-provision.sh` plus the optional
consumer-specific `DEPLOY_INIT_CMD`. `.env` regeneration and cron installation
are consumer responsibilities, done from the consumer's deploy wrapper (see
"Deploying a consumer project").

### Multiple MariaDB instances on one server

`pf-deploy.sh --init` *initializes* the project's datadir and starts its daemon via
a systemd template unit (`mariadb@<instance>`, enabled exactly once). To host
several consumers on one server, each instance must own its full runtime
identity — the Debian defaults (TCP 3306, `/run/mysqld/*`, the `/etc/mysql/`
includes) belong to the distro instance and will collide:

| Conflict | Avoid |
|---|---|
| TCP port 3306 taken by the distro `mariadb.service` or another instance | a per-project `DEPLOY_DB_PORT` (mandatory on DB hosts) |
| Default socket/pid under `/run/mysqld/` | per-project socket + pid-file under `DEPLOY_DB_BASE` (derived automatically) |
| Global `/etc/mysql/` includes inject distro paths into any started daemon | per-project defaults file `/etc/<instance>/my.cnf`, selected via `--defaults-file=/etc/%i/my.cnf` in the unit |
| Shared error log | per-project `log-error` under `DEPLOY_LOG_DIR` |
| AppArmor (Debian/Ubuntu) denies datadirs outside `/var/lib/mysql/` | per-project AppArmor profile, or disable the distro `usr.sbin.mariadbd` profile when no distro instance runs |
| Two daemons at boot | keep the distro `mariadb.service` disabled on hosts running per-project instances |

Provisioning refuses to start an instance whose socket or port is already
taken — with deliberately generic messages (no pid/owner disclosure, logs may
be read beyond the operator) — and cleans up stale pid-files/sockets left by
crashes.

The framework's `pf-deploy.sh` is a closed operation: it swaps the repo, copies the
nix closure, installs composer deps, and (with `--init`) runs provisioning — it
invokes no consumer hooks. Consumer-specific post-deploy steps (regenerate
`.env`, install cron, restart services) are added by wrapping `vendor/bin/pf-deploy.sh`
in the consumer's own deploy entrypoint (its `bin/deploy.sh` or a `make deploy`
target). `pf-deploy.sh` targets every `[prod]` host by default or a single host via
`pf-deploy.sh <host>`; a wrapper that needs per-host post steps reads the
`[prod]` roster (host → tags) via the shared `pf-roster` CLI and loops over it:

```bash
#!/usr/bin/env bash
set -euo pipefail
vendor/bin/pf-deploy.sh "$@"            # framework: swap, nix, composer, (--init)
# ... then, per prod host, regenerate .env and install cron:
#   ssh root@<host> 'cd /srv/apps/<app> && gen-env && cron-manifest > /etc/cron.d/<app>-orchestrator'
```

The framework CLIs `gen-env` and `cron-manifest` (on PATH after `composer
install`) are the intended tools for those steps.

The framework ships two more CLIs used from the consumer's deploy wrapper
(also on PATH in the consumer's dev shell and production artifact):

- **`gen-env [target-dir]`** — regenerates `.env` as a deterministic
  projection of the consumer's committed `etc/deploy.conf`
  (`REPO_PATH`/`REPO_LOG`/`REUTER_INI`/`EMA_TARGET=prod`; the `.env` stays
  `MYSQL_*`-free — the DB host's socket lives in the prod `reuter.ini`
  sections written by `gen-reuter`), with a fail-fast guard: a required
  `deploy.conf` key missing, or a
  projected key lost from the output, aborts. The deployed repo directory is
  replaced on every deploy, so the gitignored `.env` must be recreated before
  cron is installed — a missing key would silently fall back to the framework
  defaults (e.g. `EMA_TARGET=sandbox` -> wrong DB section in production).
- **`cron-manifest`** — scans the consumer's `src/` for functions decorated
  with both `#[CronJob]` and `#[Agent]` and prints a crontab to stdout
  (`CRON_USER`, and `CRON_NIX_BIN` defaulting to
  `$DEPLOY_NIX_RESULT_DIR/result/bin`, come from `etc/deploy.conf`). The
  consumer's deploy wrapper redirects it into `CRON_FILE` and restarts cron.

## Using in a consumer project

composer.json:

```json
{
  "repositories": [{ "type": "path", "url": "../php_daas_framework" }],
  "require": { "judijasa/php-daas-framework": "dev-main" }
}
```

flake.nix:

```nix
# The framework flake no longer ships framework code — it is Composer-only.
# Declare the environment binaries (php + mysqli/pdo_mysql/bz2, composer,
# mariadb, bash) in your own flake, and add vendor/bin to PATH after
# composer install (see "Dev-init machinery for consumers").
```
