# Team-member DB users — certificate-pinned accounts

Date: 2026-09-01 (mechanism implemented 2026-09-07)
Scope: how this framework turns `etc/team.ini` into one certificate-pinned,
passwordless DB account per team member, and how members obtain their client
certificates. The consumer owns the data (`etc/team.ini`) and the role policy
(the `srv/` roles packages); this framework owns the `gen-grants` and
`gen-cert` CLIs.

## Model

One DB account per team member, host-pinned to the member's machine(s):
`'member'@'<ZeroTier-IP>'`, created with a `REQUIRE SUBJECT` clause and **no**
`IDENTIFIED BY` (no password). The server validates the member's client
certificate against the team CA (the `ssl-ca` server option), and the
`REQUIRE` clause maps that certificate's subject to exactly one account.
MariaDB records the source host per connection (`user@host`), so a member is a
single identity connecting from any of their machines.

There are no passwords to generate, print, expire, or rotate: the member's
only credential is the client cert + key on their machine (used via
`mariadb --ssl-cert --ssl-key`, e.g. from `~/.my.cnf`).

### etc/team.ini

The identity registry (git-ignored; `etc/team.ini.template` committed). One
section per member; the section name IS the DB username; `subject` is the
member's certificate subject DN (passed verbatim to `REQUIRE SUBJECT`; the CN
is `<username>-<guid>`, a short random token so same-named members stay
distinct and a leaked cert is rotated by issuing a new cert with a new guid);
the remaining keys are `hostname -> ZeroTier IP` entries pinning the source
hosts.

    [john]
    subject          = /CN=john-a1b2c3d4/O=team
    john-workstation = 10.147.x.20
    john-laptop      = 10.147.x.21

## Reconcile: gen-grants

    gen-grants <db> [-n|--dry-run]

`gen-grants` reads `etc/team.ini` + the `srv/<db>.roles-<GUID>` package
(resolving its `$dependencies` to the shared `srv/roles-<GUID>` package) and
emits transient SQL (never persisted):

    -- role definitions (shared roles package first, then per-db grants)
    CREATE ROLE IF NOT EXISTS developer;
    GRANT SELECT, INSERT, UPDATE, DELETE ON <db>.* TO developer;
    -- member accounts, per member per hostname->IP
    CREATE USER IF NOT EXISTS 'john'@'10.147.x.20' REQUIRE SUBJECT '/CN=john-…/O=team';
    ALTER USER 'john'@'10.147.x.20' REQUIRE SUBJECT '/CN=john-…/O=team';
    GRANT developer TO 'john'@'10.147.x.20';
    SET DEFAULT ROLE developer FOR 'john'@'10.147.x.20';

`-n/--dry-run` prints the SQL without applying it. Otherwise it applies the
SQL as root through `ema mariadb <db> < file.sql` (run with `DBUSER=root` so
the reconcile provisions as root; run it as root on the DB host — root/
unix_socket auth over the `MYSQL_UNIX_PORT` socket from the manual reuter.ini section). The SQL is
discarded after apply.

Role definitions live in `srv/` packages (mirroring the `pkg/` convention):
the shared `srv/roles-<GUID>/` holds the role definitions (instance-level, one
copy), and each `srv/<db>.roles-<GUID>/` depends on it and holds only that
database's grants. `gen-grants` never hardcodes role names — it extracts them
from the shared package's `CREATE ROLE` statements.

## Certificates: gen-cert + offline signing

The CA private key is held **offline** (air-gapped machine or hardware token)
and never enters a networked host or the repo. `etc/team-ca.crt` is the
committed public CA certificate (installed as the server `ssl-ca`). The only
signing step is one `openssl` command run by the operator on the offline
machine.

1. **Member — generate key + CSR** (own machine):

       gen-cert new john

   reads the member's `subject` from `etc/team.ini`, generates the private
   key, and emits `john.csr`. The key never leaves the machine.

2. **Member — send `john.csr`** to the operator (email/chat/USB). The CSR is
   not secret.

3. **Operator — verify identity** out-of-band, then sign on the offline
   machine:

       openssl x509 -req -in john.csr -CA team-ca.crt -CAkey team-ca.key \
         -CAcreateserial -days 365 -out john.crt

4. **Operator — return `john.crt`** to the member.

5. **Member — install** the cert + key:

       gen-cert install john john.crt

   places them at `~/.mariadb/john.crt` and `~/.mariadb/john.key` (key mode
   `0600`) and points `~/.my.cnf [client]` `ssl-cert`/`ssl-key` at them.

6. **Member — verify** with `ema mariadb <db>` (presents the cert, no password).

## Subject vs revocation

The account trusts the *subject*, not a *specific* certificate. A routine
renewal (new key + new cert, same subject) needs no account change. Rotating a
*leaked* cert means issuing a new cert with a new `guid` (new subject) and
re-running `gen-grants` — the `ALTER USER … REQUIRE SUBJECT` it emits updates
the account, so the old cert stops matching. MariaDB does not check CRLs, so
recovering from a leaked cert otherwise means changing `REQUIRE SUBJECT` or
rotating the CA.

## team.ini replaces machines.ini [dev]

`etc/machines.ini` is now a prod-server-only roster (`[prod]` only). The
dev-machine `DBUSER` mapping moved to `etc/team.ini`:
`init-local-env.sh` finds the section whose entries include the local
`hostname` and exports its name as `DBUSER`.

## Follow-ups (not yet enforced)

- **Server TLS**: installing `ssl-ca` (from `etc/team-ca.crt`), `ssl-cert`,
  and `ssl-key` in the MariaDB config is the pending ema-side piece; until it
  lands, `REQUIRE SUBJECT` accounts cannot actually authenticate by cert.
- **`require_secure_transport=ON`** — deferred until read-only replicas exist
  (instance-wide; would force TLS on every remote client, including the
  out-of-scope service users).
- **Member removal** — the reconcile is additive today; diffing `etc/team.ini`
  against live `mysql.user` and emitting `DROP USER` for removed members is a
  follow-up when removal becomes a real case.
