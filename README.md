# php_daas_framework

A PHP framework for **data-as-a-service** agent projects: `#[Agent]` /
`#[CronJob]` attributes, DB connectivity and resumable batch primitives, and
the `phprun` CLI.

The repo is dual-role: a framework consumed by other projects, and a standalone
forkable template that behaves like one of its own consumers (the same
`make dev-init`, `bin/phprun`, and `bin/pf-deploy.sh` workflows run here as in
a consumer).

- `#[Agent]` / `#[CronJob]` — declare runnable agents, their schedules, and
  cron scope; see [doc/system/agents.md](doc/system/agents.md).
- `phprun` — runs an `#[Agent]` function, injecting a DB connection when the
  agent declares a `dbTarget`.
- `Utils\Connectivity\Database`, `Utils\DatabaseOps` (`CursorSeq`,
  `BatchInsert`, `BatchScan`), `Utils\Crawler\CasperTrio`, `Utils\Logger`.

## Quick start (dev)

1. Clone, enter the dev shell, and prepare the sandbox:

   ```bash
   git clone <repo> php_daas_framework && cd php_daas_framework
   nix develop
   make dev-init
   ```

2. Create the `test` database + dev sandbox:

   ```bash
   ema sandbox srv/test-D0PR2OGMHXDSCAR3
   ```

3. Run an agent from the repo root:

   ```bash
   bin/phprun 'src/scripts/demo/hello.php:hello()'
   ```

A PHP–MariaDB walkthrough exercising the DB layer is in
`src/scripts/demo/db_smoke.php` (run
`bin/phprun 'src/scripts/demo/db_smoke.php:main()'`). The ema integration —
sandboxes, per-database instances, and the manual `reuter.ini` — is in
[doc/system/ema.md](doc/system/ema.md).

## Deploy

```bash
bin/pf-deploy.sh                 # every [prod] host in etc/machines.ini
bin/pf-deploy.sh <target_host>   # a single prod host
```

The deploy config, host preparation, and pipeline are in
[doc/system/deploy.md](doc/system/deploy.md); private config delivery is in
[doc/system/consumer-config.md](doc/system/consumer-config.md).

## Using in a consumer project

composer.json:

```json
{
  "repositories": [{ "type": "path", "url": "../php_daas_framework" }],
  "require": { "judijasa/php-daas-framework": "dev-main" }
}
```

flake.nix (environment binaries only — framework code is Composer-only):

```nix
# declare php + mysqli/pdo_mysql/bz2, composer, mariadb, bash; add vendor/bin to PATH
```

See [doc/system/composer.md](doc/system/composer.md) for the Composer plugin
and the CLIs installed into `vendor/bin`.

## Documentation

- [agents.md](doc/system/agents.md) — `#[Agent]` / `#[CronJob]` reference.
- [composer.md](doc/system/composer.md) — Composer package and plugin.
- [consumer-config.md](doc/system/consumer-config.md) — private config delivery.
- [deploy.md](doc/system/deploy.md) — deploy config and pipeline.
- [ema.md](doc/system/ema.md) — ema integration.
- [host-hardening.md](doc/system/host-hardening.md) — tag-driven ufw firewall.
- [replica-bootstrap.md](doc/system/replica-bootstrap.md) — read-only replica.
- [service-accounts.md](doc/system/service-accounts.md) — service accounts.
- [ssh-config.md](doc/system/ssh-config.md) — dev ssh aliases.
- [team-db-users.md](doc/system/team-db-users.md) — team DB users + certs.
- [tmux-remote.md](doc/system/tmux-remote.md) — remote tmux shell.
