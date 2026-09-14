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

1. Clone, enter the dev shell, and prepare the sandbox (creates `var/log/`,
   runs `composer install`, and writes the git-ignored `.env`). The MariaDB
   instance is not started here — `ema sandbox` builds + starts it in the
   next step:

   ```bash
   git clone <repo> php_daas_framework
   cd php_daas_framework
   nix develop
   make dev-init
   ```

2. Create the `test` database + dev sandbox (git-ignored, under
   `var/sandbox/`); `ema sandbox` builds and starts the isolated MariaDB
   instance:

   ```bash
   ema sandbox srv/test-D0PR2OGMHXDSCAR3
   ```

   Optional: `cp etc/team.ini.template etc/team.ini` and add this machine's
   hostname to your member section (maps `$(hostname)` to your team DB
   username for remote DB access); and `cp etc/machines.ini.template
   etc/machines.ini` to fill in the `[prod]` ZeroTier deploy roster. Or keep
   `etc/team.ini` and `etc/machines.ini` in a private config repo and inject
   them via a git-ignored `.private-source` (see
   `doc/system/private-config.md`).

3. Re-enter the shell (or `source .env`) so the shell sees the repo paths.
   Write your agents under `src/scripts/` (see
   `src/scripts/demo/hello.php`) and run them from the repo root:

   ```bash
   bin/phprun 'src/scripts/demo/hello.php:hello()'
   ```

`phprun` loads `.env` from the current working directory (the repo root)
before doing anything else — no manual exports needed. `make dev-init`
writes `.env` with the repo paths, `REUTER_INI`, `EMA_TARGET=sandbox` and,
when `etc/team.ini` includes the local hostname, `DBUSER` (the member's team
DB username). `etc/machines.ini` is a prod-server-only roster (`[prod]` only):
each ZeroTier IP maps to comma-separated `tag[:name]` tokens (`db` and
`worker` are the built-in tags, other tags are consumer-owned; each named
token maps to exactly one server).

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
   `DEPLOY_REUTER_INI`, `DEPLOY_NIX_RESULT_DIR`, `DEPLOY_NIX_GCROOT`), and
   commit. Optional: `DEPLOY_INIT_CMD` (consumer-specific provisioning
   command run after the framework's generic `bin/pf-provision.sh`) and cron
   vars (`CRON_FILE`, `CRON_USER`). `pf-deploy.sh` fails loudly if this file is
   missing. The remote host must already have the `PROD_USER` account with
   SSH access — see "Before the first deploy" under "Deploying a consumer
   project".

The git-ignored `.env` is generated on the remote by `pf-deploy.sh` on every
deploy — there is no committed `etc/env.prod` anymore: `gen-env` (a built-in
server step, run after the repo swap) projects it deterministically
from `etc/deploy.conf` (`REPO_PATH` = `DEPLOY_TARGET_DIR`, `REPO_LOG` =
`DEPLOY_LOG_DIR`, `REUTER_INI` = `DEPLOY_REUTER_INI`,
`EMA_TARGET = prod`; the `.env` stays `MYSQL_*`-free — the DB host's socket
lives in the prod `reuter.ini` section (`MYSQL_UNIX_PORT`, recorded from
`ema create`), not in `.env`).
`gen-env` fails loudly if a required `deploy.conf` key is missing or a
projected key is lost in the output.

The local `.env` (with `REPO_PATH`) comes from `make dev-init` — machine
settings, git-ignored. Then deploy from the repo root, inside `nix develop`,
on `main`, with a clean tree:

```bash
bin/pf-deploy.sh                 # continuous deployment to every [prod] host in etc/machines.ini
bin/pf-deploy.sh <target_host>   # deploy to a single prod host (must be in [prod])
```

`pf-deploy.sh` invokes no consumer hooks; consumer-specific post-deploy steps are
added by wrapping `vendor/bin/pf-deploy.sh` (see "Deploying a consumer project"
below).

## Quick test: PHP–MariaDB integration with ema

The dev shell bundles PHP (with `pdo_mysql`), MariaDB and composer.
[`ema`](https://github.com/judijasa/ema) — a MariaDB package manager — is
Composer-delivered (`vendor/bin/ema`).
`ema sandbox` builds and starts an isolated MariaDB instance under
`var/sandbox/<name>-<guid>/` (its own datadir/socket/pid), so there is no
system DB to install. `nix develop` and `make dev-init` do not start any
daemon — the instance lifecycle is owned by ema (`ema start` / `ema stop`).

```bash
nix develop
make dev-init    # dirs, composer install, .env
source .env      # (or re-enter the shell) so the shell sees the repo paths

# 1. Create the `test` database + dev sandbox (bootstrap + schema deps)
ema sandbox srv/test-D0PR2OGMHXDSCAR3

# 2. Run the integration agent
bin/phprun 'src/scripts/demo/db_smoke.php:main()'
```

What the agent exercises, end to end:

- **`Utils\\Connectivity\\Database`** — the runner injects `$conn`, a real PDO
  connection created by `Database::connectAs('test', 'demo')` using the `[test]`
  section of `var/sandbox/test-d0pr2ogmhxdscar3/reuter.ini`.
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
  `bin/db-check`, `bin/gen-grants`, `bin/gen-service-accounts`, `bin/gen-cert`,
  `bin/cron-manifest` — the framework CLIs.
- `bin/dev/pf-shell-enter.sh`, `bin/dev/init-local-env.sh` — the dev-init
  machinery.
- `bin/pf-provision.sh` — the generic production provisioning script, invoked
  by `pf-deploy.sh` on every deploy as `vendor/bin/pf-provision.sh`.
- `bin/replica-bootstrap` — one-time transport bootstrap for a read-only
  replica (creates the `replication` account and ships a consistent snapshot);
  see `doc/system/replica-bootstrap.md`.

`gen-grants` (team-member DB accounts + roles) and `gen-cert` (member client
certificates) implement the team-DB-user flow; see
`doc/system/team-db-users.md`.

`gen-service-accounts` (passwordless, host-pinned service accounts + roles,
closed-world) implements the service-account flow; see
`doc/system/service-accounts.md`.

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
_dev-init-local-env:
        @vendor/bin/init-local-env.sh
```

`init-local-env.sh [target-dir]` (default `$PWD`) writes the repo-root `.env`
(`REPO_PATH`, `REPO_LOG`, `REUTER_INI`, `EMA_TARGET=sandbox`, and `DBUSER` when
`etc/team.ini` includes the local hostname). It does not initialize or start a
MariaDB daemon: the dev instance lifecycle is owned by ema (`ema sandbox` /
`ema start` / `ema stop`). Everything is derived from the target directory at
runtime — no consumer paths are baked in. Consumer-specific steps (git hooks,
hosts, ...) stay in the consumer's Makefile, and the dev shell shellHook
sources `pf-shell-enter.sh` (loads `.env` and sets the tmux alias; it does not
start a daemon): standalone flakes source `./bin/dev/pf-shell-enter.sh`,
consumers source `vendor/bin/pf-shell-enter.sh`.

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

## Deploying a consumer project

The repo also ships a `pf-deploy.sh` CLI (next to `phprun`) that pushes a consumer
repo to a remote production server: near-atomic swap of the repo dir, local
`nix build` + closure copy, `composer install` on every deploy (`git archive` wipes `vendor/` each time), and idempotent
provisioning on every deploy.

Standalone, the same CLI deploys this repo itself — the required committed
config (`etc/deploy.conf`) and the exact steps are in "Standalone prod init"
under "Standalone template usage". The workflow is identical to a consumer's;
only the config data differs.

```bash
pf-deploy.sh               # continuous deployment to every [prod] host in etc/machines.ini
pf-deploy.sh <target_host> # deploy to a single prod host (must be in [prod])
```

`pf-deploy.sh` reads three config surfaces from the consumer repo root:

- **`etc/deploy.conf`** (committed, required) - the project-static deployment
  target; copy from `etc/deploy.conf.template` and fill in:

| Variable | Purpose |
|---|---|
| `PROD_USER` | Unprivileged app user on the remote host. Short, deliberate name — not the repo name (e.g. `php_daas_framework` -> `daas`). Must exist with SSH access before the first deploy (see below). |
| `DEPLOY_TARGET_DIR` | Remote repo location (e.g. `/srv/apps/<app>`). |
| `DEPLOY_LOG_DIR` | Remote log dir (`deploy_version.log` lives here). |
| `DEPLOY_REUTER_INI` | Path to the consumer's manual reuter.ini — one `[<dbname>]` section per database (SERVER/PORT/DBMS/MYSQL_UNIX_PORT plus the consumer's `<ACCOUNT>_PASSWORD` keys), recorded from `ema create`'s output (or `ema values <db>` to recover). `gen-env` writes it into `.env` as `REUTER_INI`; `db-check` reads it to verify reachability. The file itself is private data, injected into `etc/` by `fetch-private-data`. |
| `DEPLOY_NIX_RESULT_DIR` | Remote nix result parent (e.g. `/usr/local/<app>`). |
| `DEPLOY_NIX_GCROOT` | Remote nix gcroot (e.g. `/nix/var/nix/gcroots/<app>`). |
| `DEPLOY_INIT_CMD` | Optional: consumer-specific provisioning command run after the framework's generic `bin/pf-provision.sh`. |
| `CRON_FILE` | Required on `worker`-tagged hosts: remote crontab file `pf-deploy.sh` installs the `cron-manifest` output into on every deploy. |
| `CRON_USER` | Optional: user the cron entries run as (default `root`). |

- **`etc/machines.ini`** (git-ignored; template committed) - the prod-server
  registry: `[prod]` ZeroTier-IP→`tag[:name]` tokens (comma-separated per
  server; `db` and `worker` are the built-in tags — `db:<name>` is the
  advisory anchor for `db-check`, bare `worker` marks a cron host — and other
  tags are consumer-owned). `pf-deploy.sh` (default mode) targets every
  `[prod]` host; a host carrying a `db:<name>` token is a database host (its
  per-database MariaDB instance is provisioned by `ema create`, not by
  deploy), and a host carrying bare `worker` gets the cron manifest
  installed. Each named token maps to exactly one server; a server may host
  several databases. The shared `pf-roster` CLI parses this roster for
  `pf-deploy.sh`, `db-check` and the consumer's deploy wrapper.
  Commit this file only in a private fork, or keep it in a separate private
  config repo and inject it via `.private-source`
  (`doc/system/private-config.md`).

- **`.env`** (git-ignored, machine-specific) - same contract as `phprun`;
  pf-deploy.sh needs `REPO_PATH` (set by the consumer's dev-init).

`pf-deploy.sh` fails loudly if `etc/deploy.conf` or `etc/machines.ini` is missing.

The prod `reuter.ini` is **manual, consumer-owned** private data (there is no
generator anymore): `ema create srv/<name>-<GUID>` provisions the database's
own MariaDB instance and prints the `[<dbname>]` section
(SERVER/PORT/DBMS/MYSQL_UNIX_PORT) for the operator to record (or
`ema values <db>` recovers a lost record). The file is injected into `etc/`
by `fetch-private-data` (see `doc/system/private-config.md`); `gen-env`
projects its path into `.env` as `REUTER_INI` from `DEPLOY_REUTER_INI`, and
`db-check` (a warn-only pf-deploy server step) verifies each section's
`SERVER:PORT` reachability on every host.

### Before the first deploy

The remote host must have the app user in place before the first `pf-deploy.sh`
— the CLI does not create it (assert-only):

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

Everything else is handled by `pf-deploy.sh` itself: the repo swap as `root`,
the idempotent provisioning via the framework's generic
`bin/pf-provision.sh` plus the optional consumer-specific `DEPLOY_INIT_CMD`,
and — on every host — the built-in server steps that regenerate `.env`
(`gen-env`) and verify DB connectivity (`db-check`, warn-only), then install
the cron manifest on `worker`-tagged hosts. A consumer wrapper is only needed
for its own consumer-owned tag steps (see "Deploying a consumer project").

### Database instances are owned by ema

`pf-deploy.sh` no longer initializes or starts any MariaDB daemon. Each
database's own instance is provisioned at **database-creation time** by
`ema create srv/<name>-<GUID>` — one instance per database (datadir,
`/etc/<instance>/my.cnf`, `mariadb@<instance>` systemd unit, auto-picked TCP
port) — and `ema create` prints the connectivity values
(`SERVER`/`PORT`/`MYSQL_UNIX_PORT`/dbname) for the operator to record in the
consumer's manual `reuter.ini` (or `ema values <db>` recovers a lost record).
Hosting several consumers on one server is therefore ema's concern, not the
deploy chain's: each `ema create` allocates a distinct port and config dir,
and the distro `mariadb.service` (TCP 3306, `/run/mysqld/*`) is left
untouched.

Deploy-time DB verification is **warn-only**: `db-check` (a built-in
pf-deploy server step) checks, on a `db:`-tagged host, that each declared
database's instance is up and its schema exists, and — on every host — that
each `reuter.ini` section's `SERVER:PORT` is TCP-reachable. It never repairs:
a miss is reported as a warning and the deploy proceeds.

The framework's `pf-deploy.sh` is a closed operation: it swaps the repo, copies the
nix closure, installs composer deps, runs idempotent provisioning, then runs
the built-in server steps (regenerate `.env`, verify DB connectivity via
`db-check`, install cron on `worker`-tagged hosts) — it invokes no consumer
hooks beyond the optional `DEPLOY_INIT_CMD`. Consumer-owned tag steps (restart
services, restore website traversal, ...) are added by wrapping
`vendor/bin/pf-deploy.sh` in the consumer's own deploy entrypoint (its
`bin/deploy.sh` or a `make deploy` target). `pf-deploy.sh` targets every
`[prod]` host by default or a single host via `pf-deploy.sh <host>`; a wrapper
that needs per-host post steps reads the `[prod]` roster (host → tags) via the
shared `pf-roster` CLI and loops over it:

```bash
#!/usr/bin/env bash
set -euo pipefail
vendor/bin/pf-deploy.sh "$@"   # framework: swap, nix, composer, provisioning, .env/db-check, cron (worker hosts)
# ... then, per prod host, the consumer-owned tag steps:
#   ssh root@<host> 'cd /srv/apps/<app> && DEPLOY_TAGS="<tags>" bin/deploy/server-side-step.sh'
```

The framework CLIs `gen-env`, `db-check` and `cron-manifest` (on PATH after
`composer install`) are the intended tools for those built-in steps; a
consumer wrapper needs them only for its own consumer-owned tags.

The framework ships three more CLIs run by pf-deploy as built-in server steps
(also on PATH in the consumer's dev shell and production artifact):

- **`gen-env [target-dir]`** — regenerates `.env` as a deterministic
  projection of the consumer's committed `etc/deploy.conf`
  (`REPO_PATH`/`REPO_LOG`/`REUTER_INI`/`EMA_TARGET=prod`; the `.env` stays
  `MYSQL_*`-free — the DB host's socket lives in the prod `reuter.ini`
  section recorded from `ema create`), with a fail-fast guard: a required
  `deploy.conf` key missing, or a
  projected key lost from the output, aborts. pf-deploy runs it right after
  the repo swap (the deployed directory is replaced on every deploy, so the
  git-ignored `.env` must be recreated before cron is installed — a missing
  key would silently fall back to the framework defaults, e.g.
  `EMA_TARGET=sandbox` -> wrong DB section in production).
- **`db-check [--host <zerotier-ip>] [--reuter-ini <path>]`** — warn-only
  connectivity verification, run on every host right after `gen-env`: on a
  `db:`-tagged host it checks each declared database's instance is up (unit
  active, socket pings, schema exists), and on every host it TCP-connects
  each `reuter.ini` section's `SERVER:PORT`. It never repairs — misses are
  warnings, and the deploy proceeds.
- **`cron-manifest`** — scans the consumer's `src/` for functions decorated
  with both `#[CronJob]` and `#[Agent]` and prints a crontab to stdout
  (`CRON_USER`, and `CRON_NIX_BIN` — pf-deploy defaults it to
  `$DEPLOY_TARGET_DIR/vendor/bin:$DEPLOY_NIX_RESULT_DIR/result/bin` so both
  `phprun` and `php` resolve — come from `etc/deploy.conf`). pf-deploy
  redirects it into `CRON_FILE` and restarts cron on `worker`-tagged hosts.

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
