# Team-member DB users — password accounts

Date: 2026-09-28 (auth changed from certificate-pinned)
Scope: how this framework turns `etc/team.ini` into one password-authenticated
DB account per team member, reachable from any host on the trusted network.
The consumer owns the data (`etc/team.ini`) and the role policy (the `pkg/`
roles packages); this framework owns the `gen-team-accounts` CLI.

## Quick setup

```bash
# 1. add each member to etc/team.ini (private, git-ignored):
#    [john]
#    password = <member password>

# 2. DB host, as root
gen-team-accounts <db> -n          # review the SQL
gen-team-accounts <db>             # apply (via ema mariadb <db> < file.sql)

# 3. the member connects with a password (mariadb -p, or ~/.my.cnf)
```

## Model

One DB account per team member, reachable from any host on the trusted
network: `'member'@'%'`, created with an `IDENTIFIED BY` password and no
`REQUIRE` clause. The identity is the *person*, authenticated by a password;
the host is deliberately not pinned (a member may connect from any device on
the ZeroTier network, gated by membership + the host firewall). MariaDB still
records the source host per connection (`user@host`).

The member's only credential is the password: there are no certificates to
issue, sign, install, or rotate.

### etc/team.ini

The identity registry (git-ignored; `etc/team.ini.template` committed). One
section per member; the section name IS the DB username; `password` is the
member's password (passed verbatim to `IDENTIFIED BY`).

    [john]
    password = <member password>

Hostname -> IP entries are no longer read by `gen-team-accounts`; a consumer keeps
them only where it still uses the `member` source for the shared service
account (`doc/system/service-accounts.md`) and for `gen-cert` (which matches
this machine's IP against them to derive the machine cert's CN — see
`doc/system/machine-certs.md`). There is no `subject` key anymore.

## Reconcile: gen-team-accounts

    gen-team-accounts <db> [-n|--dry-run]

`gen-team-accounts` reads `etc/team.ini` + the `pkg/<db>.roles-<GUID>` package
(resolving its `dependencies` to the shared `pkg/roles-<GUID>` package) and
emits transient SQL (never persisted):

    -- role definitions (shared roles package first, then per-db grants)
    CREATE ROLE IF NOT EXISTS developer;
    GRANT SELECT, INSERT, UPDATE, DELETE ON <db>.* TO developer;
    -- member accounts, one per member, any host
    CREATE USER IF NOT EXISTS 'john'@'%' IDENTIFIED BY '<password>';
    ALTER USER 'john'@'%' IDENTIFIED BY '<password>';
    GRANT developer TO 'john'@'%';
    SET DEFAULT ROLE developer FOR 'john'@'%';

`-n/--dry-run` prints the SQL without applying it. Otherwise it applies the
SQL as root through `ema mariadb <db> < file.sql` (the reconcile provisions as
root; run it as root on the DB host — root/unix_socket auth over the
`MYSQL_UNIX_PORT` socket from the manual reuter.ini section). The SQL is
discarded after apply.

Role definitions live in `pkg/` packages, alongside the schema packages: the
shared `pkg/roles-<GUID>/` holds the role definitions (instance-level, one
copy), and each `pkg/<db>.roles-<GUID>/` depends on it and holds only that
database's grants. `gen-team-accounts` never hardcodes role names — it extracts them
from the shared package's `CREATE ROLE` statements.

## Passwords vs revocation

Rotation is a `team.ini` edit + a `gen-team-accounts <db>` re-run: the `ALTER USER …
IDENTIFIED BY` it emits updates the password in place. There is no certificate
subject to revoke.

## team.ini replaces machines.ini [dev]

`etc/machines.ini` is now a prod-server-only roster (`[prod]` only).
`DBUSER` is consumer policy: `init-local-env.sh` no longer derives it from
`etc/team.ini`; the consumer writes its own `DBUSER`.

## Follow-ups (not yet enforced)

- **`require_secure_transport=ON`** — deferred (instance-wide; would force TLS
  on every remote client, including the out-of-scope service users). Until it
  (or per-account `REQUIRE SSL`) lands, passwords traverse the network
  unencrypted.
- **Member removal** — the reconcile is additive today; diffing `etc/team.ini`
  against live `mysql.user` and emitting `DROP USER` for removed members is a
  follow-up when removal becomes a real case.
- **Password characters** — `etc/team.ini` is parsed raw; a password with a
  leading `;`/`#` or embedded quotes needs care from the operator.
- **Migration from the cert-pinned shape** — the old `'member'@'<ip>'
  REQUIRE SUBJECT` accounts are separate `mysql.user` rows from the new
  `'member'@'%'`; a consumer switching over must drop the old rows itself (and
  may then remove `subject` from `etc/team.ini`).
- **`gen-cert`** — repurposed as the machine-cert CLI
  (`doc/system/machine-certs.md`); the member `subject` flow described here
  moved to passwords (`doc/system/service-accounts.md`).
