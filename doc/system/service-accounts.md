# Service accounts — passwordless, host-pinned, role-based

Date: 2026-09-14
Scope: how this framework turns a consumer's declaration into a closed-world
set of passwordless, host-pinned service accounts and roles, from the shared
`srv/roles-<GUID>` package, `etc/team.ini` and `etc/machines.ini`. The
framework owns the mechanism (`bin/gen-service-accounts`); the consumer owns
the data (role definitions, per-database grants, account/source mapping, team
roster, host registry, allow-list and role namespace) and the *account model*
— one shared account pinned to many sources, several accounts with disjoint
sources, or anything in between.

## Model

One passwordless DB account per service account, host-pinned to the set of
machines whose sources map to roles it should hold: `'app'@'<ZeroTier-IP>'`,
created with `IDENTIFIED BY ''` (no password — the security boundary is the
host pin plus the transport network). Roles are used deliberately so the
reconcile is **closed-world on role memberships**, not on a privilege-set
comparison: the desired state per account per host is the union of the roles
for that host's sources; excess roles are revoked, and any direct (non-role)
grants are blanket-revoked as drift.

There are no passwords to generate, print, expire or rotate. An account is
created on a database only where it holds at least one role: a `web`-only
account exists on the read database and is dropped on the write database.

### Declaration

The shared `srv/roles-<GUID>/default.php` carries the declaration (all
consumer data — no account name, role name or source is hardcoded):

    $sources  = array('member' => 'developer', 'worker' => 'worker'); // source -> role
    $accounts = array('app' => array('member', 'worker', 'db', 'web')); // account -> sources
    $allowlist = array('daas'); // accounts the drop pass must never remove

- `$sources` maps a source to the role it grants. `member` resolves to the
  `etc/team.ini` IPs; any other key is a `etc/machines.ini` `[prod]` tag
  (bare, or `db:<name>`), matched exactly.
- `$accounts` maps an account name to the sources whose hosts it is pinned to.
  Its per-host roles are the union of those sources' roles, intersected with
  the roles that hold a `GRANT` on the target database.
- `$allowlist` (optional) adds accounts the closed-world drop must never
  remove. `root` and `mariadb.sys` are an always-on safety floor: they are
  never dropped, and a declared `$allowlist` extends (never replaces) them.
  Accounts the consumer creates itself (e.g. `replication` via
  `replica-bootstrap`) are not covered by the floor and must be declared here.

`upgrade.sql` carries the `CREATE ROLE` and per-database `GRANT … TO <role>`
DDL exactly as `gen-grants` consumes today; `{{dbname}}` is filled from the
target database. A role with no `GRANT` on a database means its account is not
wanted there, which drives the per-instance drop set. Absent declaration
(`$sources`/`$accounts`) = today's `gen-grants` team-member shape: no service
accounts are reconciled.

## Reconcile: gen-service-accounts

    gen-service-accounts <db> [-n|--dry-run]

`gen-service-accounts` reads the shared roles package (`CREATE ROLE` names,
`$sources`, `$accounts`, `$allowlist`) and, for the target database, its
`$dependencies`-resolved per-database grants package, then emits transient SQL
(never persisted) in four phases:

1. **role definitions + per-database grants** — the shared `CREATE ROLE`, then
   the per-db `GRANT`, in declaration order;
2. **service accounts** — per account per host, `CREATE USER IF NOT EXISTS`
   (passwordless, host-pinned), `ALTER USER`, `GRANT <role> TO`, then
   `SET DEFAULT ROLE` (the roles activate on connect);
3. **revoke** — excess roles, then the direct (non-role) grants of the managed
   database: `REVOKE GRANT OPTION ON <db>.*`, then `REVOKE ALL PRIVILEGES ON
   <db>.*`;
4. **drop** — undeclared accounts (instance-wide), declared accounts that hold
   no role on this database, and orphaned roles.

The closed-world diff reads live state from `mysql.user`,
`mysql.roles_mapping`, and `mysql.db` (the direct db-level grants on the managed
database, which gate the Phase 3 revokes). Accounts are global in `mysql.user`
(only the GRANT is per-database), so the user/role drop set is instance-wide and
is emitted identically on each per-database run — idempotent.

`-n/--dry-run` prints the SQL without applying it. Otherwise it applies the
SQL through `ema mariadb <db>`, with `EMA_TARGET=prod` pinned: the reconcile is
prod-only, so an operator shell in sandbox mode must not redirect it. The SQL is
discarded after apply.

The CLI runs from the **operator machine**: planning reads `etc/team.ini`,
`etc/machines.ini` and `srv/*` — private roster data that never leaves it — and
only the SQL execution crosses the network. The target is the host carrying the
database's `db:<name>` `[prod]` token (the framework's one-to-one server
mapping); the CLI reaches it as `root` over `ssh` and runs the deployed repo's
own `ema mariadb <db>` there, from the deployed repo root (`DEPLOY_TARGET_DIR`,
read from the consumer's `etc/deploy.conf` — see `doc/system/consumer-config.md`).
On its own host that call takes ema's local path: the section's
`MYSQL_UNIX_PORT` socket as root (unix_socket auth), exactly as in an on-host
run.

The reconcile therefore carries no database identity of its own: no `DBUSER`, no
password, no privileged account on the TCP port, and nothing to add to
`$allowlist`. It is a dev-machine verb — a host carries no roster, so a host-side
run has no `db:<name>` token to resolve and plans nothing.

## Fail-open ordering

Apply order is deliberate: create + grant roles first, grant roles to users
and set defaults second, revoke (roles, then direct grants) third, drop last.
A partial failure therefore leaves a host holding a *superset* — never locked
out — and re-running converges. The full role union per host is computed
before anything is applied, so the result does not depend on apply order.

A revoke failure is retried once; a second failure aborts with the failed SQL
written to stderr and a non-zero exit.

## Notes

- **The reconcile carries no database identity of its own** — it picks no
  `DBUSER` and holds no credentials: it reaches the host as `root` over `ssh` and
  runs the host's own `ema` there, so there is no privileged TCP account to
  create, allow-list or rotate. `ema`'s own transport rules (the section's socket
  as root on its host, `SERVER`/`PORT` as `DBUSER` elsewhere) are unchanged for
  every other verb that calls it.
- **Direct-grant drift** — two statements, scoped to the managed database (never
  `*.*`): `REVOKE GRANT OPTION ON <db>.*`, then `REVOKE ALL PRIVILEGES ON
  <db>.*`. `ALL PRIVILEGES, GRANT OPTION` in one statement is not valid MariaDB
  syntax, and `ALL PRIVILEGES` on its own leaves the grant option behind. Both
  are emitted only for accounts the live `mysql.db` read reports as holding a
  db-level grant: on a role-only account — every account on a re-run — they fail
  with `ERROR 1141` (no such grant).
- **Namespace cleanup** — `DROP ROLE` targets only the declared role namespace
  (`CREATE ROLE` names plus `$sources` roles) and never the account
  allow-list.
- **`gen-grants` unification** — the cert-pinned team-member flow
  (`gen-grants`, `doc/system/team-db-users.md`) and this passwordless
  service-account flow share the reconcile skeleton but differ in auth mode
  (`REQUIRE SUBJECT` vs passwordless) and population (one-per-member vs
  declared). Unifying them is deferred until a third account family appears —
  there is no shared declaration grammar yet.
