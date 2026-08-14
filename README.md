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
- **`Utils\Connectivity\Database`** — PDO wrapper with `admin`/`reader`/`public`
  roles, resolving its config from the consumer's environment.
- **`Utils\DatabaseOps`** — `CursorSeq`, `BatchInsert`, `BatchScan`: resumable
  batch processing with persisted cursors.
- **`Utils\Crawler\CasperTrio`**, **`Utils\Logger`** — casperjs subclass and a
  tiny timestamped logger.

```bash
phprun 'path/to/script.php:my_agent($arg=1)'
```

The runner:

1. Validates that the target function carries the `#[Agent]` attribute.
2. If the agent declares `dbTarget: 'dbname'`, it opens a connection via
   `Utils\Connectivity\Database::admin($dbTarget)` and injects it as the first
   argument of the call.
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

The repo also works as a **forkable template** — a plain PHP project you clone
and build on directly:

```bash
git clone <repo> php_daas_framework
cd php_daas_framework
cp etc/reuter.ini.template etc/reuter.ini   # fill in DB credentials
composer install                            # generates vendor/ + casperjs/phantomjs binaries
```

Write your agents under `src/scripts/` (see `src/scripts/demo/hello.php`) and
run them with:

```bash
printf 'export REPO_PATH=%s\nexport REPO_LOG=%s/var/log\n' "$PWD" "$PWD" > .env
bin/phprun 'src/scripts/demo/hello.php:hello()'
```

`phprun` loads `.env` from the current working directory (the repo root)
before doing anything else — no manual exports needed.

In template mode the classes are autoloaded from the framework's **own**
`vendor/autoload.php`, and `etc/reuter.ini` is resolved from the repo root.
The same code base is consumed as a library by other projects (see below) —
both modes share the identical `Utils\` classes in `src/`.

## Quick test: PHP–MariaDB integration with ema

The dev shell bundles PHP (with `pdo_mysql`), MariaDB, composer and
[`ema`](https://github.com/judijasa/ema) — a MariaDB package manager.
It initializes and starts an isolated MariaDB on a
unix socket under `var/` automatically, so there is no system DB to install.

```bash
nix develop

# 1. DB config (git-ignored). DBNAME=test is what the demo expects.
cp etc/reuter.ini.template etc/reuter.ini

# 2. Composer dependencies (vendor/ + casperjs/phantomjs binaries)
composer install

# 3. Create the `test` database + users, then the schema packages
ema init db test
ema init tables demo-8C3A9E1F0D2B4C5D

# 4. Run the integration agent
bin/phprun 'src/scripts/demo/db_smoke.php:main()'
```

What the agent exercises, end to end:

- **`Utils\Connectivity\Database`** — the runner injects `$conn`, a real PDO
  connection created by `Database::admin('test')` using the `[local]` section
  of `etc/reuter.ini` and the `MYSQL_UNIX_PORT` socket.
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

Re-running the agent is safe: `ema init db test` resets the whole database, or
skip it and watch `BatchScan` resume from the cursor stored in `cursorseq`.

The building blocks behind steps 3–4 live in the repo:

| Path | Purpose |
|---|---|
| `srv/test.sql` | Database + user bootstrap consumed by `ema init db test` |
| `pkg/cursorseq-*/` | `cursorseq` table (contract of `CursorSeq`/`BatchScan`) |
| `pkg/items-*/` | demo `items` table |
| `pkg/demo-*/` | root schema package listing the dependencies in order |
| `src/scripts/demo/db_smoke.php` | the agent exercising the DB layer |


## Distribution

This repo is dual-delivered:

- **composer package** (`judijasa/php-daas-framework`): the PHP library under
  the `Utils\` PSR-4 namespace, plus the `bin/phprun` and `bin/deploy` wrappers (installed by
  composer as `vendor/bin/phprun` and `vendor/bin/deploy`).
- **nix flake** (`packages.default`): installs `bin/phprun`, `bin/deploy` and `src/phprun.php`
  into the nix store. Add as an input and drop into your `commonPackages` to get
  `phprun` and `deploy` on PATH (dev shell and production artifact).


## Environment variables

`phprun` loads its runtime configuration from a `.env` file in the current
working directory (the consumer repo root) before doing anything else. This
is the canonical way to configure a deployment: generate `.env` per
environment (e.g. `make dev-init` in dev, or at deploy time in prod) and
invoke `phprun` from the repo root. Values in `.env` override anything
already in the process environment; if neither provides the required
variables, `phprun` fails loudly.

| Variable | Purpose |
|---|---|
| `REPO_PATH` | Consumer repo root. `phprun` must be run from here (when invoked from cron it cds here automatically). |
| `REPO_LOG` | Directory where per-script logs are appended. |
| `REUTER_INI` | Path to the DB config ini consumed by `Utils\\Connectivity\\Database`; falls back to `$PWD/etc/reuter.ini`. |
| `EMA_TARGET` | Section of the ini to use (`local`, `prod`, ...). |
| `MYSQL_UNIX_PORT` | Optional unix socket appended to the DSN. |

## Deploying a consumer project

The repo also ships a `deploy` CLI (next to `phprun`) that pushes a consumer
repo to a remote production server: near-atomic swap of the repo dir, local
`nix build` + closure copy, conditional `composer install`, and optional
one-time provisioning (`--init`).

```bash
deploy <target_host>          # continuous deployment
deploy --init <target_host>   # + one-time provisioning
```

`deploy` reads two config surfaces from the consumer repo root:

- **`etc/deploy.conf`** (committed, required) - the project-static deployment
  target; copy from `etc/deploy.conf.template` and fill in:

| Variable | Purpose |
|---|---|
| `PROD_USER` | Unprivileged app user on the remote host. |
| `DEPLOY_TARGET_DIR` | Remote repo location (e.g. `/srv/apps/<app>`). |
| `DEPLOY_LOG_DIR` | Remote log dir (`deploy_version.log` lives here). |
| `DEPLOY_NIX_RESULT_DIR` | Remote nix result parent (e.g. `/usr/local/<app>`). |
| `DEPLOY_NIX_GCROOT` | Remote nix gcroot (e.g. `/nix/var/nix/gcroots/<app>`). |
| `DEPLOY_INIT_CMD` | Optional: remote shell command for `--init` provisioning. |
| `CRON_FILE` | Optional: remote crontab file installed by the consumer's post-nix hook. |
| `CRON_USER` | Optional: user the cron entries run as (default `root`). |

- **`.env`** (git-ignored, machine-specific) - same contract as `phprun`;
  deploy needs `REPO_PATH` (set by the consumer's dev-init).

`deploy` fails loudly if `etc/deploy.conf` is missing. Consumer-specific
tasks hook into the deploy flow via two optional scripts in the deployed
repo, which `deploy` runs on the remote if present:

- **`bin/deploy/post-swap.sh`** — right after the atomic swap, before nix
  packages are copied. Must be plain bash (no framework CLIs, no nix php on
  the remote yet).
- **`bin/deploy/post-nix.sh`** — after the nix closure and composer deps are
  in place (and, for `--init`, after provisioning). The framework CLIs and
  nix php are available here, so this is where the consumer regenerates
  `.env` and installs cron.

The framework ships two more CLIs used by those hooks (also on PATH in the
consumer's dev shell and production artifact):

- **`gen-env [target-dir]`** — regenerates `.env` from the consumer's
  committed `etc/env.prod` template (export-style lines, git-ignored output),
  with a fail-fast guard: every content line of the template must end up in
  the file. The deployed repo directory is replaced on every deploy, so the
  gitignored `.env` must be recreated before cron is installed — a missing
  key would silently fall back to the framework defaults (e.g.
  `EMA_TARGET=local` -> wrong DB section in production).
- **`cron-manifest`** — scans the consumer's `src/` for functions decorated
  with both `#[CronJob]` and `#[Agent]` and prints a crontab to stdout
  (`CRON_USER`, and `CRON_NIX_BIN` defaulting to
  `$DEPLOY_NIX_RESULT_DIR/result/bin`, come from `etc/deploy.conf`). The
  consumer's hook redirects it into `CRON_FILE` and restarts cron.

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
inputs.php_daas_framework.url = "github:judijasa/php_daas_framework";
# ... add php_daas_framework.packages.${system}.default to commonPackages
```
