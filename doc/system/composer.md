# Composer — package and plugin

How this repo is built and shipped as a Composer package, and what its
Composer plugin does on a consumer's `composer install` / `composer update`.
The consumer side (pinning `judijasa/php-daas-framework` and `judijasa/ema` to
`dev-main#<hash>`, `allow-plugins`, `repositories`) is documented in the
consumer's own `doc/system/composer.md`.

## composer.json

```json
{
  "name": "judijasa/php-daas-framework",
  "type": "composer-plugin",
  "license": "MIT",
  "require": {
    "php": ">=8.1",
    "ext-mysqli": "*",
    "ext-pdo_mysql": "*",
    "ext-bz2": "*",
    "composer-plugin-api": "^2.0",
    "phpcasperjs/phpcasperjs": "^1.3",
    "jerome-breton/casperjs-installer": "dev-master",
    "jakoch/phantomjs-installer": "3.0.3",
    "judijasa/ema": "dev-main"
  },
  "scripts": {
    "post-install-cmd": ["Utils\\Plugin::installCrawlerToolchain"],
    "post-update-cmd": ["Utils\\Plugin::installCrawlerToolchain"]
  },
  "extra": {
    "class": "Utils\\Plugin"
  },
  "autoload": {
    "psr-4": {
      "Utils\\": "src/"
    }
  },
  "bin": [
    "bin/phprun",
    "bin/pf-deploy.sh",
    "bin/gen-env",
    "bin/db-check",
    "bin/gen-grants",
    "bin/gen-service-accounts",
    "bin/gen-cert",
    "bin/pf-roster",
    "bin/cron-manifest",
    "bin/dev/pf-shell-enter.sh",
    "bin/dev/init-local-env.sh",
    "bin/pf-provision.sh",
    "bin/pf-server-steps.sh",
    "bin/replica-bootstrap",
    "bin/gen-ssh-config",
    "bin/gen-firewall",
    "bin/tmux-remote"
  ],
  "repositories": [
    { "type": "vcs", "url": "https://github.com/judijasa/ema" }
  ],
  "require-dev": {
    "composer/composer": "^2"
  }
}
```

Key fields:

- `type: composer-plugin` + `extra.class: Utils\Plugin` — this package is a
  Composer plugin; Composer activates `Utils\Plugin` on install/update (see
  The plugin).
- `require` — the framework's own dependencies: PHP + the
  `mysqli`/`pdo_mysql`/`bz2` extensions, the Composer plugin API, the crawler
  installer packages (`phpcasperjs/phpcasperjs`,
  `jerome-breton/casperjs-installer`, `jakoch/phantomjs-installer`), and
  `judijasa/ema`.
- `scripts.post-install-cmd` / `post-update-cmd` — fire only when this repo is
  the root project (standalone template); a plugin does not self-activate as
  root, so these reference the same `Utils\Plugin::installCrawlerToolchain`
  method directly.
- `autoload.psr-4` — the `Utils\` namespace maps to `src/`.
- `bin` — the CLIs/scripts Composer installs into the root's `vendor/bin` (see
  Delivered CLIs).
- `require-dev` — `composer/composer` only (the plugin API implementation used
  by `Utils\Plugin` in dev).
- `repositories` — VCS source for `judijasa/ema`, which is not on Packagist.

## The plugin

`src/Plugin.php` (`Utils\Plugin`) implements Composer's `PluginInterface` and
`EventSubscriberInterface`. It subscribes to the `post-install-cmd` and
`post-update-cmd` script events and runs `installCrawlerToolchain`, which does
two things on every consumer `composer install` / `composer update`:

1. **`installCasperJs`** — invokes `CasperJsInstaller\Installer::install` to
   place PhantomJS then CasperJS into the root project's `bin-dir`, applying
   three scoped workarounds (all restored immediately afterwards):
   - `OPENSSL_CONF=/dev/null` — PhantomJS bundles an outdated OpenSSL that
     chokes on modern `openssl.cnf`.
   - `PHANTOMJS_EXECUTABLE=$bin-dir/phantomjs` — the CasperJS probe needs to be
     pointed at the phantomjs binary.
   - `PHANTOMJS_CDNURL` — Bitbucket no longer serves the official PhantomJS
     binaries (HTTP 402); fall back to a GitHub mirror unless the consumer
     already configured a source.
2. **`patchPhpcasperjs`** — patches
   `vendor/phpcasperjs/phpcasperjs/src/Casper.php`, rewriting
   `private $script` to `protected $script`, which `Utils\Crawler\CasperTrio`
   (`src/Crawler/CasperTrio.php`) needs in order to subclass it.

`activate` / `deactivate` / `uninstall` are no-ops — the plugin has no
lifecycle beyond the two script subscriptions.

## Delivered CLIs

The `bin` array installs these into `vendor/bin` (or the project's configured
`bin-dir`):

- `phprun`, `cron-manifest` — agent execution and cron generation (see
  `doc/system/agents.md`).
- `pf-deploy.sh`, `pf-provision.sh`, `pf-server-steps.sh`, `gen-env`,
  `db-check`, `pf-roster` — the deploy chain (see `doc/system/deploy.md`).
- `gen-grants`, `gen-cert` — team-member DB users (see
  `doc/system/team-db-users.md`).
- `gen-service-accounts` — service accounts (see
  `doc/system/service-accounts.md`).
- `replica-bootstrap` — read-replica bootstrap (see
  `doc/system/replica-bootstrap.md`).
- `gen-ssh-config` — dev ssh aliases (see `doc/system/ssh-config.md`).
- `gen-firewall` — host hardening (see `doc/system/host-hardening.md`).
- `tmux-remote` — remote tmux shell (see `doc/system/tmux-remote.md`).
- `pf-shell-enter.sh`, `init-local-env.sh` — the dev-init machinery.

`ema` itself is not listed here: it is a separate Composer package
(`judijasa/ema`) that installs its own `vendor/bin/ema` alongside these CLIs.
