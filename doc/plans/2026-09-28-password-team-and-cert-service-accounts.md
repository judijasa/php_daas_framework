# Password team accounts + cert-pinned service accounts — Plan & Progress

Date: 2026-09-28
Repos: php_daas_framework (this repo); ema (../ema).

## Decision

Split the two account families onto the credential each matches:

- **Members are people.** `gen-team-accounts` switches from certificate-pinned
  (`REQUIRE SUBJECT`) to **password** (`IDENTIFIED BY '<password>'`), and drops
  the source-IP pin (`'member'@'<ip>'` → `'member'@'%'`): the identity is the
  person, authenticated by a password, reachable from any device on the trusted
  network. The password is consumer data — a `password` field per member in
  `etc/team.ini`. The old per-member + IP + cert shape mixed a person identity
  with device credentials.
- **Service accounts are machines.** `gen-service-accounts` gains a `require`
  field on `RolesConfig` (in `../ema`). When set (e.g. `'X509'`), the reconcile
  emits `REQUIRE <value>` on `CREATE USER`/`ALTER USER`, so the shared
  passwordless account additionally requires a client certificate — closing the
  source-IP spoofing hole (a member of the trusted network claiming a pinned IP)
  without re-adding passwords to a machine account.

Out of scope: `gen-cert` (member cert issuance) is left in place, now orphaned
by the member-flow change; consumer-side declaration/`team.ini` edits, server
TLS, and Composer pinning are consumer follow-ups.

## Config model

`etc/team.ini` (consumer-owned private data), per member:

    [john]
    password = <member password>
    # hostname -> IP entries are no longer read by gen-team-accounts (kept only for
    # the shared service account's `member` source)

`pkg/roles-<GUID>/default.php` (shared declaration):

    roles: new \Ema\Config\RolesConfig(
        sources: [...], accounts: [...], allowlist: [...],
        require: 'X509',   // optional; absent = passwordless as today
    ),

## Reconcile shapes

    -- gen-team-accounts (members)
    CREATE USER IF NOT EXISTS 'john'@'%' IDENTIFIED BY '<password>';
    ALTER USER 'john'@'%' IDENTIFIED BY '<password>';
    GRANT <role> TO 'john'@'%';
    SET DEFAULT ROLE <role> FOR 'john'@'%';

    -- gen-service-accounts (shared account, require set)
    CREATE USER IF NOT EXISTS 'simox'@'<ip>' IDENTIFIED BY '' REQUIRE X509;
    ALTER USER 'simox'@'<ip>' IDENTIFIED BY '' REQUIRE X509;
    GRANT <role> TO 'simox'@'<ip>';
    SET DEFAULT ROLE <role> FOR 'simox'@'<ip>';

## Changes

### ema (../ema)

- [x] `src/Config/RolesConfig.php` — add `public readonly ?string $require = null`
      and carry it in `toArray()`.

### php_daas_framework (this repo)

- [x] `bin/gen-team-accounts` — read `password` instead of `subject`; emit one
      `'member'@'%'` account per member with `IDENTIFIED BY '<password>'` (no
      `REQUIRE`, no hostname->IP iteration); update the header note and `--help`.
- [x] `bin/gen-service-accounts` — `package_declaration()` reads `roles->require`;
      `compute_plan()`/`build_setup_sql()` emit `REQUIRE <value>` on
      `CREATE USER`/`ALTER USER` when set; `team_ips()` skips `password` as well
      as `subject`; update the phase-2 comment and `--help`.
- [x] `etc/team.ini.template` — `password` field in place of `subject`.
- [x] `doc/system/team-db-users.md` — password model (drop the cert/CSR flow).
- [x] `doc/system/service-accounts.md` — document `require` and the
      `REQUIRE <value>` emission; note the instance-wide drop vs member accounts.
- [x] `README.md` — team-db-users summary line: passwords, not certs.
- [x] `doc/plans/2026-09-28-password-team-and-cert-service-accounts.md` — this doc.

## Open items

- **`gen-service-accounts` Phase 4 drops member accounts** — its closed-world
  drop is instance-wide on `mysql.user` and removes any account whose name is
  neither declared (`accounts`) nor allow-listed. A consumer running both flows
  on one instance must allow-list the member names, or the drop must be scoped
  to a service-account namespace. Pre-existing; surfaces only when both
  families are active.
- **Server TLS is a hard prerequisite** — `REQUIRE X509` (and a password over
  the wire) needs `ssl-ca`/`ssl-cert`/`ssl-key` live. `require_secure_transport`
  stays deferred (instance-wide).
- **Password lifecycle returns** — `gen-team-accounts` re-introduces passwords to
  generate, store (private `team.ini`), rotate and distribute; previously none.
- **`team.ini` password characters** — INI parsing is raw; a password with a
  leading `;`/`#` or embedded quotes needs operator care.
- **`'member'@'%'` widens the surface** — from the pinned device to any host on
  the trusted network; the boundary is ZeroTier membership + the host firewall.
- **`gen-cert` is now orphaned** — member cert issuance no longer feeds
  `gen-team-accounts`; keep for manual/machine cert issuance or retire separately.
- **`replication` account** — still created passwordless, host-pinned by
  `replica-bootstrap`; not covered by the `require` path unless the consumer
  certs it too.
- **Composer pinning** — the `RolesConfig.require` field lands in `../ema`, so
  this repo must pin `judijasa/ema` to a pushed commit before the `require`
  field is usable at runtime (see the pin procedure); consumers pin this repo in
  turn.
- **Migration** — pre-existing `'member'@'<ip>' REQUIRE SUBJECT` accounts are
  separate `mysql.user` rows from the new `'member'@'%'`; a consumer switching
  over must drop the old rows.
