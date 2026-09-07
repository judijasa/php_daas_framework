# Team-member DB users — Plan & Progress

Date: 2026-09-01
Repos: php_daas_framework (this repo); ../ema (the `ema apply` mechanism).
       Consumers carry the team registry + role policy via their own plans.

## Decision

Create one DB account per team member, host-pinned to that member's dev
machine(s), so a member is a single identity (`john`) that connects from any
of their machines over ZeroTier. MariaDB already records the source host per
connection (account = `user@host`; processlist/audit show it), so per-member
identity is observable without per-machine usernames.

The identity registry moves out of `etc/machines.ini [dev]` (hostname →
DBUSER) into a new `etc/team.ini` (member → hostname → ZeroTier IP); the
member's DB username is the section name. `machines.ini` becomes a pure
prod-server roster (`[prod]` only).

Authentication is certificate-based, not password-based:

    client certificate
        ↓
    TLS validates the certificate against the team CA (ssl-ca)
        ↓
    MariaDB account uses REQUIRE X509 / SUBJECT / ISSUER
        ↓
    account has no password
        ↓
    database access

Each member holds a client certificate issued by a team CA. The DB account
is created with a `REQUIRE` clause (default `REQUIRE SUBJECT`, the per-member
pin; `REQUIRE ISSUER` / `REQUIRE X509` are the looser alternatives) and **no**
`IDENTIFIED BY`. The server validates the presented certificate against the
CA certificate configured as `ssl-ca`; the `REQUIRE` clause then maps that
certificate to exactly one account. There are no passwords to generate,
print, expire, or rotate: the member's only credential is the cert + key on
their machine (used via `mariadb --ssl-cert --ssl-key`, e.g. from
`~/.my.cnf`).

Privileges have one tracked source of truth, organized as `srv/` packages
(mirroring the `pkg/` convention). The role definitions live in one shared
package (`srv/roles-<guid>`) and are therefore the same for every database;
each per-database package (`srv/<name>.roles-<guid>`) depends on it and adds
only that database's grants. Initially one default role (`developer`) for
every member; per-member role divergence is deferred.

Policy (not enforced): the ema bootstrap (`ema sandbox` / `ema create`),
the DB creation step, emits no team grants. Team grants are applied
separately, at will, targeting one database via `gen-grants <db>`.

The mechanism is a reconcile: a framework CLI (`gen-grants`) reads
`etc/team.ini` + the `srv/<name>.roles-<guid>` package (resolving its
`$dependencies` to the shared roles package), emits transient SQL, and
applies it as root through `ema mariadb <db> < file.sql`. ema stays
mechanism-only; the framework owns the team.ini format + reconcile + the team
CA and cert issuance; the consumer owns the data and the role policy.

Out of scope: the service users (`admin`/`reader`/`public`) and their
host-pinning; password-based auth; `unix_socket` / Kerberos auth.

## Config model

| File | Committed | Secrets? | Consumed where |
|---|---|---|---|
| `etc/team.ini` | no (`.template` yes) | no (identity + cert subject) | dev (`init-local-env.sh` → DBUSER), prod DB host (`gen-grants` → accounts) |
| `etc/team-ca.crt` | yes | no (public CA cert) | prod DB host (`ssl-ca`), members (optional `--ssl-ca`) |
| `etc/machines.ini` | no (`.template` yes) | no | dev + prod (`pf-deploy.sh`, `gen-reuter`, `pf-roster`) — `[prod]` only after this |
| `srv/roles-<guid>/`, `srv/<name>.roles-<guid>/` | yes | no | prod DB host (`gen-grants` → roles + grants) |
| `etc/reuter.ini` | no (generated) | yes (ADMIN/READER_PASSWORD) | app layer + `ema` (unchanged) |

`etc/team.ini` shape (section = DB username; `subject` = that member's client
certificate subject DN, passed verbatim to `REQUIRE SUBJECT`; the CN is
`<username>-<guid>` — a short random token — so two members with the same
name stay distinct and a compromised cert is rotated by issuing a new cert
with a new `guid`; the hostname → ZeroTier IP entries pin the source host):

```ini
[john]
subject          = /CN=john-a1b2c3d4/O=team
john-workstation = 10.147.x.20
john-laptop      = 10.147.x.21

[jane]
subject          = /CN=jane-9f8e7d6c/O=team
jane-workstation = 10.147.x.30
```

Roles are packages under `srv/`, mirroring the `pkg/` convention: each
package is a `<name>-<GUID>/` directory whose GUID uses schematic's
type-prefixed form (a 2-char kind prefix + 14 base36 chars) — `S0` for
`pkg/` schema packages, `D0` for `srv/` database packages. A `default.php`
declares `$dependencies` (an array of package directory names) and nothing
else, and the SQL sits in `upgrade.sql`. The role definitions live once in
the shared roles package, so every database sees the same roles; each
per-database package depends on it and holds only that database's grants.
`<name>` is the database name.

Shared roles package (role definitions, instance-level, one copy):

```text
srv/roles-D04XRV7T92MKQ5N1/
  default.php   # $dependencies = array();
  upgrade.sql   # CREATE ROLE IF NOT EXISTS developer;
```

Per-database package (grants only; depends on the roles package):

```text
srv/test.roles-D0W3P8HL6TQK2B9R/
  default.php   # $dependencies = array('roles-D04XRV7T92MKQ5N1');
  upgrade.sql   # GRANT SELECT, INSERT, UPDATE, DELETE ON {{dbname}}.* TO developer;
```

## Mechanism & data ownership

- **ema** owns the mechanism only: `ema mariadb <db> < file.sql>` runs
  arbitrary SQL against a resolved section, reusing the existing root/socket
  + sudo logic. No knowledge of team.ini, roles, or certs.
- **framework** owns the format + reconcile: `bin/gen-grants [db]` reads
  `etc/team.ini` + the `srv/<db>.roles-<guid>` package (resolving its
  `$dependencies` to the shared `srv/roles-<guid>` package) and, per
  member/ip, emits transient SQL (never persisted):
  - `CREATE USER IF NOT EXISTS 'member'@'ip' REQUIRE SUBJECT '<subject>';`
    (no `IDENTIFIED BY` — the account has no password)
  - `ALTER USER 'member'@'ip' REQUIRE SUBJECT '<subject>';` when the
    subject changes (cert rotation with a new `guid`, or re-issue).
  - `GRANT <role> TO 'member'@'ip';` and `SET DEFAULT ROLE <role> FOR 'member'@'ip';`
  - `DROP USER IF EXISTS 'member'@'ip';` for members no longer in team.ini.
  There is no secret to print or deliver; the SQL is discarded after apply.
- **framework** also owns the team CA + cert flow: `bin/gen-cert` is the
  member-side helper (generate key + CSR, install the returned cert; subject
  from `etc/team.ini`). The CA cert is `etc/team-ca.crt`; the CA key is held
  **offline** by the operator and is the only thing that signs member certs
  (see the workflow below).
- **consumer** owns the data (`etc/team.ini`) and the policy
  (`srv/roles-<guid>/` + `srv/<name>.roles-<guid>/`). Adding a member = add a
  section to team.ini, issue a cert, and re-run `gen-grants`; changing
  privileges = edit the role/grants packages.

`gen-grants` resolves each per-database package's `$dependencies` (the shared
roles package comes first, so `CREATE ROLE` precedes the grants) and never
hardcodes role names; it runs as root over the socket on the DB host (same
auth as `ema init db`).

## Offline signing workflow

The CA private key is held offline (air-gapped machine or hardware token) and
never enters a networked host or the repo. `bin/gen-cert` is the member-side
helper; the one signing step is an `openssl` command run by the operator on
the offline machine.

1. **Member — generate key + CSR** (own machine): `bin/gen-cert new john`
   reads `etc/team.ini`, generates a private key, and emits `john.csr` (public
   key + the member's `subject`). The private key never leaves the member's
   machine.
2. **Member — send `john.csr`** to the operator (email/chat/USB). The CSR is
   not secret.
3. **Operator — verify the requester's identity** out-of-band (confirm it is
   really `john` before signing — the subject is what opens the account), then
   sign on the offline machine:

   ```
   openssl x509 -req -in john.csr -CA team-ca.crt -CAkey team-ca.key \
     -CAcreateserial -days 365 -out john.crt
   ```

   This is the only step that touches the CA private key.
4. **Operator — return `john.crt`** to the member.
5. **Member — install** the cert + key: `bin/gen-cert install john john.crt`
   places them at `~/.mariadb/john.crt` and `~/.mariadb/john.key` (key mode
   `0600`), and points `~/.my.cnf [client]` `ssl-cert`/`ssl-key` at them.
6. **Member — verify** with `ema mariadb` (presents the cert, no password).

`gen-cert new` takes the subject from `etc/team.ini`, so the CSR subject always
matches the account's `REQUIRE SUBJECT` emitted by `gen-grants`.

Note: the account trusts the *subject*, not a *specific* certificate. A
routine renewal (new key + new cert, same subject) needs no account change.
Rotating a *leaked* cert means issuing a new cert with a new `guid` (new
subject) and `ALTER USER`-ing the account to it — the old cert stops matching
and is effectively revoked, since MariaDB does not check CRLs. Recovering from
a leaked cert otherwise means changing `REQUIRE SUBJECT` or rotating the CA.

## Changes

### php_daas_framework (this repo)

- [x] `etc/team.ini.template` (new): the member-section schema above (section
      = username, `subject` key with `<username>-<guid>` CN, hostname → IP
      entries) + usage comments.
- [x] `.gitignore`: add `/etc/team.ini`.
- [x] `etc/team-ca.crt` (new, committed): the public team CA cert, installed
      as the server `ssl-ca`.
- [x] `etc/machines.ini.template`: drop `[dev]`; document it as a
      prod-server-only registry.
- [x] `bin/dev/init-local-env.sh`: resolve `DBUSER` from `etc/team.ini` (find
      the section whose entries include `$(hostname)`; `DBUSER` = section
      name) instead of `machines.ini [dev]`.
- [x] `bin/gen-grants` (new): the reconcile CLI above (`REQUIRE SUBJECT`, no
      password), resolving the `srv/` roles-package `$dependencies`.
- [x] `bin/gen-cert` (new): member-side helper — `gen-cert new <member>`
      generates the private key + CSR (subject from `etc/team.ini`), and
      `gen-cert install <member> <cert>` installs the operator-returned cert
      at `~/.mariadb/` (key mode `0600`). It never touches the CA key
      (offline, operator-held).
- [x] `srv/roles-<guid>/` + `srv/test.roles-<guid>/` (new example packages):
      the shared `developer` role definition + the `test`-database grant, with
      the grant package depending on the roles package.
- [x] `composer.json`: add `bin/gen-grants` and `bin/gen-cert` to the `bin`
      array.
- [x] `doc/system/team-db-users.md` (new): the offline signing workflow
      (`~/.mariadb/` + `chmod 600`), the subject-vs-revocation caveat, the
      `team.ini` → account reconcile, and the `[dev]` → `team.ini` move.
- [x] `README.md`: quick setup + overview only — add a short pointer to
      `doc/system/team-db-users.md`; update `[dev]`/DBUSER references.
- [x] `Makefile`, `bin/dev/pf-shell-enter.sh`, `bin/dev/init-local-env.sh`:
      stop starting/resuming the dev MariaDB daemon — `nix develop` and
      `make dev-init` no longer launch a shared instance; the per-instance
      sandbox lifecycle is owned by ema (`ema sandbox` / `ema start` /
      `ema stop`).

### ema (../ema)

- [x] `ema database` creates `srv/<name>-D0<GUID>/` (generic `default.php`
      + `upgrade.sql`) and `ema schema` GUIDs are `S0`-prefixed; `ema init
      db` reads `srv/<name>-<GUID>/upgrade.sql`; flat `srv/<name>.sql` is
      removed (committed in ../ema).
- [x] `ema mariadb <db> < file.sql` — raw SQL over stdin as the section's
      client user (supersedes the removed `ema apply` verb; committed in
      ../ema). No team.ini/roles/cert knowledge.
- [ ] Server TLS: provision `ssl-ca` (from `etc/team-ca.crt`), `ssl-cert`,
      and `ssl-key` in the MariaDB config. (`require_secure_transport=ON` is a
      separate follow-up — see Open items.)
      Policy (not enforced): the ema bootstrap (`ema sandbox` / `ema create`)
      emits no *team* grants — those come only from `gen-grants <db>`, run at
      will against one database.
- [ ] `ema mariadb` client: pass `--ssl-cert`/`--ssl-key` (or rely on the
      member's `~/.my.cnf [client]`), so the client presents the cert instead
      of a password.
- [ ] `README.md`: document `ema mariadb <db> < file.sql` and the cert-based
      client flags.

## Open items

- CA key custody details: the key is held offline (decided); remaining choices
  are the storage medium (air-gapped laptop vs. hardware token), and the
  backup/rotation/recovery plan if that medium is lost or the CA must rotate.
- `REQUIRE` granularity: `SUBJECT` (per-member, default) vs `ISSUER`
  (CA-wide, every cert from the CA opens every account) vs `X509` (any valid
  cert) vs `SUBJECT AND ISSUER` (member + CA pin). Start with `SUBJECT`.
- Cert lifecycle: MariaDB does not check CRLs by default, so a revoked/expired
  cert keeps validating until `REQUIRE SUBJECT` is updated or the CA rotates.
  Decide the renewal (`gen-cert` + `ALTER USER`) and revocation flow.
- `require_secure_transport=ON` — **follow-up**, deferred until read-only
  replicas exist. It is instance-wide and would force TLS on every remote
  (TCP) client, including the out-of-scope service users
  (`admin`/`reader`/`public`). Local Unix-socket connections count as a secure
  transport and stay permitted, so an app on the DB host can keep reading over
  the socket without TLS. The later split: replicas serve the public
  read-only websites (no TLS requirement), while the primary MariaDB instances
  — the originals, reached by members over ZeroTier — can be set to
  `require_secure_transport=ON`.
- Member removal: diff `etc/team.ini` against live `mysql.user` (accounts
  holding our roles) vs. a persisted manifest — **revisit when** removal
  becomes a real case; additive reconcile is the immediate need. Cert
  revocation is part of the same flow.
- Per-member role divergence: move role assignment into `etc/team.ini` —
  **no** for now (single `developer` for everyone).
- `ema mariadb <db> < file.sql` interface: whether it mirrors the
  `-n`/`--no-shell` flag parity of the other ema subcommands (the old
  `ema apply` verb is gone).
