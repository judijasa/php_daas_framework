# Deploying a consumer project

How `pf-deploy.sh` pushes a consumer repo (or this repo, standalone) to a
production server. The ema side — how each database gets its own MariaDB
instance and how the manual `reuter.ini` is recorded — is in
`doc/system/ema.md`; this document covers the deploy config, the host
preparation, and the fixed pipeline.

## Config surfaces

`pf-deploy.sh` reads three config surfaces from the repo root and fails loudly
if `etc/deploy.conf` or `etc/machines.ini` is missing.

### `etc/deploy.conf`

The deployment target (consumer-owned; template at `etc/deploy.conf.template`).

| Variable | Purpose |
|---|---|
| `PROD_USER` | Unprivileged app user on the remote host. Short, deliberate name — not the repo name. Must exist with SSH access before the first deploy. |
| `DEPLOY_TARGET_DIR` | Remote repo location (e.g. `/srv/apps/<app>`). |
| `DEPLOY_LOG_DIR` | Remote log dir (`deploy_version.log` lives here). |
| `DEPLOY_REUTER_INI` | Path to the consumer's manual reuter.ini. `gen-env` writes it into `.env` as `REUTER_INI`; `db-check` reads it to verify reachability. |
| `DEPLOY_NIX_RESULT_DIR` | Remote nix result parent (e.g. `/usr/local/<app>`). |
| `DEPLOY_NIX_GCROOT` | Remote nix gcroot (e.g. `/nix/var/nix/gcroots/<app>`). |
| `DEPLOY_INIT_CMD` | Optional consumer-specific provisioning command run after the framework's `pf-provision.sh`. |
| `CRON_FILE` | Required whenever the repo declares a `#[CronJob]` attribute: remote crontab file `pf-deploy.sh` installs the scope-filtered `cron-manifest` output into on every host. |
| `CRON_USER` | Optional user the cron entries run as (default `root`). |
| `CRON_NIX_BIN` | Optional `PATH` override for the cron entries (default `$DEPLOY_TARGET_DIR/vendor/bin:$DEPLOY_NIX_RESULT_DIR/result/bin`). |

### `etc/machines.ini`

The prod-server registry: `[prod]` ZeroTier-IP → `tag[:name]` tokens
(comma-separated per server). `db:<name>` names a database; every tag doubles
as a cron `scope`; other tags are consumer-owned. `pf-deploy.sh` (default mode)
targets every `[prod]` host; a host carrying a `db:<name>` token is a database
host (its instance is provisioned by `ema create`, not deploy). Each named
token maps to exactly one server; a server may host several databases. The
shared `pf-roster` CLI parses this roster. This file is private data (see
`doc/system/consumer-config.md`).

### `.env`

Same runtime contract as `phprun`. `pf-deploy.sh` needs `REPO_PATH` (set by
the consumer's dev-init); the remote `.env` is regenerated on every deploy by
`gen-env` (see the pipeline below).

| Variable | Purpose |
|---|---|
| `REPO_PATH` | Repo root. `phprun` must be run from here (from cron it cds here automatically). |
| `REPO_LOG` | Directory where per-script logs are appended. |
| `REUTER_INI` | Path to the DB config ini consumed by `Utils\Connectivity\Database`; falls back to `$PWD/etc/reuter.ini`. |
| `EMA_TARGET` | Operation-mode flag for the `ema` CLI only (`sandbox` / `prod`). The app layer ignores it; a database is always resolved to its `[<dbname>]` section. |

## Before the first deploy

The remote host must have the app user in place before the first
`pf-deploy.sh` — the CLI does not create it (assert-only):

1. Create the app user (`PROD_USER`) as root:

   ```bash
   useradd --create-home --shell /bin/bash --comment "Production app user" <PROD_USER>
   passwd --lock <PROD_USER>
   ```

   `--create-home` is required (the nix installation stores per-user state in
   `~<PROD_USER>`); `passwd --lock` disables password login, making the SSH key
   the only entry point.

2. Install SSH access for that user (the same public key used to log in as
   `root`):

   ```bash
   mkdir -p /home/<PROD_USER>/.ssh && chmod 700 /home/<PROD_USER>/.ssh
   echo "<ssh-ed25519 AAAA... your-key>" >> /home/<PROD_USER>/.ssh/authorized_keys
   chmod 600 /home/<PROD_USER>/.ssh/authorized_keys
   chown -R <PROD_USER>:<PROD_USER> /home/<PROD_USER>/.ssh
   ```

   `pf-deploy.sh` SSHes in as both `root` and `<PROD_USER>` — the nix closure
   copy and `composer install` run as the app user.

3. Install a cron daemon — required only when the consumer declares
   `#[CronJob]` jobs (the deploy's cron step writes the crontab and restarts
   the daemon). The unit name is distro-specific (`cron` on Debian/Ubuntu,
   `crond` on RHEL/Fedora, `cronie` on Arch/Alpine); the deploy detects the
   installed one and fails with an actionable message when none is present.

The multi-user nix install (performed automatically when absent) assumes a
systemd host with `curl` available.

## The pipeline

```bash
pf-deploy.sh                 # every [prod] host in etc/machines.ini
pf-deploy.sh <target_host>   # a single prod host (must be in [prod])
```

The fixed pipeline: swap the repo (as `root`), copy the nix closure,
`composer install` (the archive wipes `vendor/`), ship the private files named
in `DEPLOY_PRIVATE_FILES`, run `pf-provision.sh` (which installs the shared
`mariadb@.service` unit) + the optional `DEPLOY_INIT_CMD`, then the built-in
server steps:

1. **`gen-env`** — regenerate `.env` as a deterministic projection of
   `etc/deploy.conf` (`REPO_PATH`/`REPO_LOG`/`REUTER_INI`/`EMA_TARGET=prod`;
   `MYSQL_*`-free — the DB host's socket lives in the prod `reuter.ini`
   section). Fail-fast: a missing `deploy.conf` key, or a projected key lost
   from the output, aborts.
2. **`db-check`** — warn-only connectivity verification: checks the host's own
   `mariadb@<db>` instances are up (unit active, socket pings, schema exists)
   and TCP-connects each `reuter.ini` section's `SERVER:PORT`. Never repairs.
3. **`cron-manifest`** — scan `src/` for functions carrying both `#[CronJob]`
   and `#[Agent]` and emit the scope-filtered crontab to `CRON_FILE`, then
   restart cron (on every host; `host`-scoped jobs run everywhere).

Consumer-owned tag steps (restart services, restore website traversal, ...) are
added by wrapping `vendor/bin/pf-deploy.sh` in the consumer's own deploy
entrypoint:

```bash
#!/usr/bin/env bash
set -euo pipefail
vendor/bin/pf-deploy.sh "$@"   # framework pipeline (every host, scope-filtered)
# ... then, per prod host, the consumer-owned tag steps.
```

Database instances are not part of deploy: each database's own MariaDB instance
is provisioned at creation time by `ema create srv/<name>-<GUID>` (see
`doc/system/ema.md`). Deploy does install the shared `mariadb@.service`
template unit (via `pf-provision.sh`), which `ema create` asserts before
provisioning any instance.
