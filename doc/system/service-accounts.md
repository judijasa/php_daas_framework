# Service accounts — passwordless, host-pinned, role-based

Date: 2026-09-14
Scope: how this framework turns a consumer's declaration into a closed-world
set of passwordless, host-pinned service accounts and roles, from the shared
`pkg/roles-<GUID>` package, `etc/team.ini` and `etc/machines.ini`. The
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

The shared `pkg/roles-<GUID>/default.php` carries the declaration as a nested
`Ema\Config\RolesConfig` on the package's `PackageConfig` (all consumer data —
no account name, role name or source is hardcoded):

    return new \Ema\Config\PackageConfig(
        roles: new \Ema\Config\RolesConfig(
            sources:   ['member' => 'developer', 'worker' => 'worker', 'web' => 'webapp'],
            accounts:  ['app' => ['member', 'worker', 'web']],
            allowlist: ['daas'],
            require:   'X509',
        ),
    );

- `sources` maps a source to the role it grants. `member` resolves to the
  `etc/team.ini` IPs; any other key is a `etc/machines.ini` tag
  (bare, or `db:<name>`), matched exactly. Every source an account names must
  itself be declared here.
- `accounts` maps an account name to the sources whose hosts it is pinned to.
  Its per-host roles are the union of those sources' roles, intersected with
  the roles that hold a `GRANT` on the target database.
- `allowlist` (optional) adds accounts the closed-world drop must never
  remove. `root` and `mariadb.sys` are an always-on safety floor: they are
  never dropped, and a declared `allowlist` extends (never replaces) them.
  Accounts the consumer creates itself (e.g. `replication` via
  `replica-bootstrap`) are not covered by the floor and must be declared here.
- `require` (optional) is a TLS/certificate clause — e.g. `'X509'` — emitted
  as `REQUIRE <value>` on every `CREATE USER`/`ALTER USER` this reconcile
  emits. It hardens the passwordless, host-pinned account against a trusted
  peer spoofing the source IP (the host pin alone is forgeable on the trusted
  network; a client certificate is not). Absent (or `null`), accounts stay
  plain `IDENTIFIED BY ''` — the pre-existing shape. Server `ssl-ca`/`ssl-cert`
  /`ssl-key` must be live before a `require` value can authenticate (see
  `doc/system/team-db-users.md` follow-ups).

`upgrade.sql` carries the `CREATE ROLE` and per-database `GRANT … TO <role>`
DDL exactly as `gen-team-accounts` consumes today; `{{dbname}}` is filled from the
target database. A role with no `GRANT` on a database means its account is not
wanted there, which drives the per-instance drop set. An absent declaration (no
nested `RolesConfig`, or one with an empty `accounts`) = today's `gen-team-accounts`
team-member shape: there is nothing to reconcile, and the CLI says so and
exits non-zero.

## Reconcile: gen-service-accounts

    gen-service-accounts <db> [-n|--dry-run]

`gen-service-accounts` reads the shared roles package (`CREATE ROLE` names and
its `RolesConfig` fields `sources`, `accounts`, `allowlist`) and, for the
target database, its `dependencies`-resolved per-database grants package, then
emits transient SQL (never persisted) in four phases:

1. **role definitions + per-database grants** — the shared `CREATE ROLE`, then
   the per-db `GRANT`, in declaration order;
2. **service accounts** — per account per host, `CREATE USER IF NOT EXISTS`
   (passwordless, host-pinned; `REQUIRE <value>` when `require` is declared),
   `ALTER USER`, `GRANT <role> TO`, then `SET DEFAULT ROLE` (the roles
   activate on connect);
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
`etc/machines.ini` and `pkg/*.roles-*` — private roster data that never leaves it — and
only the SQL execution crosses the network. The target is the host carrying the
database's `db:<name>` roster token (the framework's one-to-one server
mapping); the CLI reaches it as `root` over `ssh` and runs the deployed repo's
own `ema mariadb <db>` there, from the deployed repo root (`DEPLOY_TARGET_DIR`,
read from the consumer's `etc/deploy.conf` — see `doc/system/consumer-config.md`)
and with the deployed `vendor/bin` plus the nix result bin
(`$DEPLOY_NIX_RESULT_DIR/result/bin`, see `doc/system/deploy.md`) on the remote
`PATH`: a host has no `php` on `PATH` — the deploy delivers it as the nix result
— and `ema`'s wrapper calls a bare `php`.
On its own host that call takes ema's local path: the section's
`MYSQL_UNIX_PORT` socket as root (unix_socket auth), exactly as in an on-host
run.

The reconcile therefore carries no database identity of its own: no `DBUSER`, no
password, no privileged account on the TCP port, and nothing to add to
`allowlist`. It is a dev-machine verb — a host carries no roster, so a host-side
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
  (`CREATE ROLE` names plus the `sources` roles) and never the account
  allow-list.
- **`gen-team-accounts` unification** — the team-member flow (`gen-team-accounts`,
  `doc/system/team-db-users.md`) and this service-account flow share the
  reconcile skeleton but differ in auth mode (`IDENTIFIED BY` password,
  one-per-member `@'%'`, vs passwordless host-pinned, optionally
  `REQUIRE <value>`) and population (one-per-member vs declared). Unifying
  them is deferred until a third account family appears — there is no shared
  declaration grammar yet.
- **Instance-wide drop vs member accounts** — Phase 4 drops any account whose
  name is neither declared (`accounts`) nor allow-listed, instance-wide. A
  consumer that runs *both* `gen-team-accounts` (member accounts) and
  `gen-service-accounts` on one instance must allow-list the member names, or
  the drop will remove them. This surfaces only when the two families are
  active together.
