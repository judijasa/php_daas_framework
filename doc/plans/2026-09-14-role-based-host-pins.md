# Role-based host-pin reconcile — Plan & Progress

Date: 2026-09-14
Repos: php_daas_framework (this repo).

## Decision

Move the role-based closed-world host-pin reconcile into the framework as a
generic CLI: `bin/gen-service-accounts`. The framework owns the mechanism
(the declaration format + the reconcile); a consumer owns the data (its role
definitions, per-database grants, account/source mapping, team roster, and
host registry) and the *account model* — one shared account pinned to a set
of sources, several accounts with disjoint sources, or anything in between.
No account name, role name, grant, or source is hardcoded in the framework.

This supersedes the service-account half of
`doc/plans/2026-09-07-ema-schema-only-and-service-users.md`, which removed a
`bin/gen-service-users` prototype because it named accounts. That removal was
right about *naming*; it threw out the *mechanism* with the names. The new CLI
reads every name from the declaration, so it is generic where the removed
prototype was not.

Roles are used deliberately so the reconcile is closed-world without a
privilege-set comparison: it diffs **role memberships**, not `GRANT`
privileges. Desired state per account per host is the union of the roles for
the host's sources; excess roles are revoked, and any direct (non-role) grants
are blanket-revoked as drift. Escalate-only is rejected (a role removal would
become a no-op, leaving a demoted host holding its old privileges).

## Config model

Data contract (all consumer-owned):

| Surface | What it holds |
|---|---|
| `srv/roles-<GUID>/` (shared, instance-level) | role definitions (`CREATE ROLE`) + the account/source declaration (`$sources`, `$accounts` in `default.php`) |
| `srv/<db>.roles-<GUID>/` | per-database grants (`GRANT <privilege> ON {{dbname}}.* TO <role>`) |
| `etc/team.ini` | the `member` source (member IPs) |
| `etc/machines.ini` `[prod]` | the tag sources — bare tags (`worker`, `web`, any consumer tag) and the `db:<name>` family |

The shared `default.php` gains two optional declarations (absent = today's
`gen-grants` shape):

    $sources  = array('member' => 'developer', 'worker' => 'worker'); // source -> role
    $accounts = array('app' => array('member', 'worker', 'db', 'web')); // account -> sources

A source is either `member` (team.ini IPs) or a `machines.ini` tag. `upgrade.sql`
carries the `CREATE ROLE` / `GRANT … TO <role>` DDL exactly as `gen-grants`
consumes today; `{{dbname}}` is filled from the target database. A role with no
`GRANT` on a database means its account is not wanted there, which drives the
per-instance drop set.

## Mechanism

`bin/gen-service-accounts <db>` (mirroring `gen-grants <db>`) replaces the
consumer-owned per-project script:

1. read the shared roles package (`CREATE ROLE` names, `$sources`,
   `$accounts`) and, for the target database, its per-db grants package;
2. resolve each source to a host set — `member` (team.ini IPs) or a
   `machines.ini` tag (bare, or `db:<name>`);
3. per account, compute the union of roles across the account's sources and
   the host set for that union;
4. emit, per database: `CREATE ROLE` + `GRANT` (declaration order), then per
   account per host `CREATE USER` (passwordless, host-pinned), `GRANT <role>
   TO`, `SET DEFAULT ROLE`; then the closed-world pass — `REVOKE <excess
   role> FROM`, a blanket `REVOKE ALL PRIVILEGES ON <db>.*` for direct
   (non-role) grants, `DROP USER` for undeclared accounts, and `DROP ROLE`
   for undeclared roles in the consumer's namespace.

Accounts are global in `mysql.user`; only the GRANT is per-database, so the
user/role drop set is instance-wide and emitted identically on each
per-database run (idempotent). An account is created on a database only where
it holds at least one role (a `web`-only account exists on the read database
and is dropped on the write database). The allow-list (`root`, `mariadb.sys`,
`replication`) and the role namespace (cleanup scope) are declaration data,
not constants.

Ordering: create + grant roles first, grant roles to users and set defaults
second, revoke (roles, then direct grants) third, drop last — a partial
failure leaves a host with a superset (fail-open), never locked out, and
re-running converges. Revoke failure: retry `ema mariadb <db>` once, then
abort and report (failed SQL to stderr, non-zero exit). Order independence:
the full role union per host is computed before anything is applied.

## Changes

### php_daas_framework (this repo)

- [x] `bin/gen-service-accounts` (new) — generic reconcile per the Mechanism
      section; reads the declaration + team.ini + machines.ini (reusing the
      `pf-roster` parse), emits closed-world SQL, applies via
      `ema mariadb <db>` with `DBUSER=root`. `-n/--dry-run`.
- [x] `composer.json` — add `bin/gen-service-accounts` to the `bin` array.
- [x] `doc/system/service-accounts.md` (new) — declaration contract + reconcile
      semantics (parallel to `doc/system/team-db-users.md`).
- [x] `README.md` — Distribution list + a pointer to the new doc.
- [x] `srv/roles-<GUID>/default.php` — document the optional `$sources` /
      `$accounts` keys (absent = today's `gen-grants` shape).
- [x] `doc/plans/2026-09-14-role-based-host-pins.md` — this doc.

## Open items

- **Direct-grant drift** — confirm the blanket `REVOKE ALL PRIVILEGES ON
  <db>.*` clears `GRANT OPTION` (a separate `REVOKE GRANT OPTION ON <db>.*`
  may be needed) and that its scope is the managed databases only, not `*.*`.
- **Role activation** — confirm `SET DEFAULT ROLE` makes the granted roles
  active on connect for the pinned MariaDB version, and that the drift check
  enumerates role memberships (not expanded privileges).
- **Namespace cleanup** — verify `DROP ROLE` targets only the
  consumer-declared namespace and never the account allow-list.
- **`gen-grants` unification** — the cert-pinned team-member flow
  (`gen-grants`, `doc/system/team-db-users.md`) and this passwordless
  service-account flow share the reconcile skeleton but differ in auth mode
  (cert `REQUIRE SUBJECT` vs passwordless) and population (one-per-member vs
  declared). Unifying them is deferred until a third account family appears —
  **no** shared declaration grammar now.
