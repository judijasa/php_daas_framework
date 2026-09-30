# Machine certs and client SSL wiring — Plan & Progress

Date: 2026-09-29
Repos: php_daas_framework (this repo)

## Decision

Make the app-layer connection and the operator CLI able to present a TLS client
certificate, so that a consumer's MariaDB service accounts can be created with
`REQUIRE X509` (server verifies the client) without any change to how a
connection is opened. The cert material is one directory holding `client.crt` +
`client.key`; the framework derives the two paths from a single directory value
and ships the machine-cert CLI that mints the material and writes the client
drop-in.

Three mechanism pieces, all value-agnostic (values stay consumer data):

1. `Database::connectAs()` reads `SSL_DIR` and, when set, passes
   `MYSQL_ATTR_SSL_CERT`/`MYSQL_ATTR_SSL_KEY` (derived `<SSL_DIR>/client.crt`
   and `<SSL_DIR>/client.key`). Unset → no SSL attributes, plain TCP exactly as
   today. The attributes are added in the prod/TCP path only — the sandbox
   socket path never applies TLS.
2. The dev-side consumer options move out of the consumer's Makefile into an
   `etc/dev.conf` that the framework sources: the framework owns the
   materialization + sourcing, so only non-derived consumer-chosen values live
   in the file and derived values stay derived.
3. The orphaned `bin/gen-cert` is repurposed as the machine-cert CLI: bare
   `gen-cert` mints key+CSR (CN = this machine's pinned name, derived by
   matching its local IPv4 against `etc/team.ini` — no argument, no GUID),
   `gen-cert install <client.crt>` places the signed cert and writes the
   `~/.my.cnf.d/<repo-dir>.cnf` drop-in, mirroring `bin/gen-ssh-config`. (The
   member/`subject`-from-`team.ini` flow that `gen-cert` used to serve moved to
   passwords in
   `doc/plans/2026-09-28-password-team-and-cert-service-accounts.md`, leaving it
   orphaned.)

Out of scope: the `require` declaration, the CA, and the server-side `ssl-ca`
emission (consumer data and a sibling repo's mechanism). Client-side server
verification (the client verifying the *server*) is out for v1 — see Open items.

## Changes

### php_daas_framework (this repo)

- [x] `src/Connectivity/Database.php` — `connectAs()` reads `SSL_DIR`; when set,
      set `MYSQL_ATTR_SSL_CERT`/`MYSQL_ATTR_SSL_KEY` from `<SSL_DIR>/client.crt`
      and `<SSL_DIR>/client.key` (prod/TCP path only).
- [x] `bin/gen-env` — surface `DEPLOY_SSL_DIR` into `.env` as `SSL_DIR` (the
      `REUTER_INI` precedent), optional (no hard-fail).
- [x] `bin/dev/init-local-env.sh` — source `etc/dev.conf` and relay the
      consumer-chosen dev values (`DBUSER`, `SSL_DIR`) into `.env`.
- [x] `bin/gen-cert` — repurposed as the machine-cert CLI: bare `gen-cert`
      mints key+CSR (`openssl req`, CN = this machine's pinned name, matched by
      local IPv4 against `etc/team.ini`, no GUID) and `gen-cert install
      <client.crt>` writes `client.crt`/`client.key` into the SSL dir +
      idempotently writes `~/.my.cnf.d/<repo-dir>.cnf` `[client]` ssl-cert/
      ssl-key, reusing the `bin/gen-ssh-config` tagged-region + atomic-rename
      pattern. The SSL dir is read from `etc/dev.conf`'s `SSL_DIR`, never
      hardcoded.
- [x] `etc/dev.conf.template` (new) + `.gitignore` `/etc/dev.conf`.
- [x] `etc/deploy.conf.template` `DEPLOY_SSL_DIR`; docs — new
      `doc/system/machine-certs.md`, and cross-refs in `consumer-config.md`,
      `deploy.md`, `ssh-config.md`, `team-db-users.md`, `composer.md`,
      `README.md`.
- [x] `etc/ema.conf.template` (new) + `.gitignore` `/etc/ema.conf` — the
      consumer-facing shape of the host-level `ema` config (`ssl-ca`, the
      server half of `REQUIRE X509`), mirroring the sibling repo's template, with
      the `DEPLOY_PRIVATE_FILES` requirement documented in `consumer-config.md`,
      `ema.md` and `machine-certs.md`.

## Open items

- **Client-side server verification — out for v1, recorded (not dismissed).**
  The reverse direction (client verifies the server via `ssl-ca`) is symmetric
  in difficulty but needs CA-signed *server* certs — a larger change. Follow-up.
- **SSL-directory env var name — resolved: `SSL_DIR`.** One name on both sides:
  prod reads it from `etc/deploy.conf` `DEPLOY_SSL_DIR` → `gen-env` → `.env`;
  dev reads it from `etc/dev.conf` `SSL_DIR` → `gen-cert`. The handoff's
  two-name split (`SSL_DIR` / `DEV_MYSQL_SSL_DIR`) was dropped — same mechanism,
  different consumer data on different machines, different config sources.
- **Revocation** — no CRL is consumed anywhere, so a leaked machine cert cannot
  be revoked. CA-side concern, not this repo's mechanism.
