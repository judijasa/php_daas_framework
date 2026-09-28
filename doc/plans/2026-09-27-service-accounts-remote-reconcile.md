# Service-account reconcile from the operator machine — Plan & Progress

Date: 2026-09-27
Repos: php_daas_framework (this repo); ../ema (upstream package).

## Decision

`gen-service-accounts` assumes it runs **on the database host**: it shells out to
`ema mariadb <db>`, which resolves the instance's local socket, and
root/unix_socket auth is host-local. Its declaration inputs are the opposite.
`etc/team.ini` (the `member` source) and `etc/machines.ini` (the tag sources) are
consumer private data that exists only on the machine that runs the reconcile —
`doc/system/consumer-config.md` states the invariant, "None of them belong on a
host". The two requirements are mutually exclusive: the CLI can read its inputs
only where it cannot reach the database.

Move the CLI to the **operator machine** (dev/deploy side) and let ema's
transport carry the database I/O (../ema): off-host it reaches the instance by
itself, at the section's `SERVER`/`PORT`, as an explicit SQL user. Planning stays
local — it needs the private roster — and only the SQL execution crosses the
network. No additional private file ships to a host, so the invariant holds and
a host never carries roster data as runtime authority.

The transport is **TCP as `DBUSER`, not an SSH root hop** (../ema, commit
16d11d9). ema rejected the root-over-SSH variant: the instance's root is a
socket-auth identity (`unix_socket` maps the OS user), meaningful only on its
own host, so an inferred remote root path would be a second, arbitrary way into
the DB host. The reconcile therefore connects off-host as an account the
**operator** supplies — `DBUSER`, with `DBPASS`/`MYSQL_PWD`/`~/.my.cnf` when it
has a password — which must be TCP-capable and hold the reconcile's privileges.
That is consumer policy, like every other account here, and the same shape
`replica-bootstrap` already gives its `replication` transport account
(`doc/system/replica-bootstrap.md`): passwordless, host-pinned to the operator
machine, created by the operator, who already has root SSH to the host. On the
DB host itself nothing changes: `DBUSER` unset means `$USER` — root, over the
section's own socket.

The CLI pins `EMA_TARGET=prod` on its ema invocation rather than inheriting the
ambient value: it is a prod-only reconcile, and an operator shell in sandbox mode
must not be able to redirect it.

This also makes `-n/--dry-run` faithful: it reads live state over the same
transport, so the printed SQL includes the closed-world revoke/drop set it
currently omits.

Out of scope: the declaration grammar, the four-phase ordering, the fail-open
behaviour, and the account model.

## Topology

    operator machine             database host
    ────────────────             ─────────────
    etc/team.ini      ┐
    etc/machines.ini  ┤ plan     (roster never leaves this machine)
    srv/*.roles-*     ┘
    etc/reuter.ini    ─┐
                       ├ transport ──► tcp $SERVER:$PORT as $DBUSER
    live state  ◄──────┘                 (passwordless, host-pinned)

## Changes

### php_daas_framework (this repo)

- [x] `bin/gen-service-accounts` — `run_query()` / `apply_sql()`: pin
      `EMA_TARGET=prod` on the ema invocation and call `ema mariadb <db>` as-is
      (ema resolves local-vs-off-host by itself); drop the `DBUSER=root` prefix
      — on the DB host ema falls back to `$USER` (root, over the socket), and
      off-host the operator's `DBUSER`/`DBPASS` is the only identity a TCP
      connection can carry.
- [x] `bin/gen-service-accounts` — `run_query()`: stop discarding the client's
      stderr (`2>/dev/null`) so a transport or auth failure surfaces the real
      client error instead of the generic "could not read live account/role
      state" hint.
- [x] `bin/gen-service-accounts` — reword the live-state guard and the header
      note: the failure mode is now transport reachability, not "run it as root
      on the DB host".
- [x] `doc/system/service-accounts.md` — replace the "run it as root on the DB
      host / root/unix_socket over the `MYSQL_UNIX_PORT` socket" paragraph with
      the operator-machine + transport model, and state the off-host account's
      prerequisites, `$allowlist` included.
- [x] `composer.lock` — follow ema HEAD (`composer update judijasa/ema`) to the
      commit that adds the off-host transport. `composer.json` keeps
      `"judijasa/ema": "dev-main"`, as on every previous ema follow: the lock's
      `reference` is what pins the commit.
- [x] `bin/gen-service-accounts` — Phase 3: emit the direct-grant revoke as two
      valid statements (`REVOKE GRANT OPTION ON <db>.*`, then `REVOKE ALL
      PRIVILEGES ON <db>.*`). The single `REVOKE ALL PRIVILEGES, GRANT OPTION ON
      <db>.*` is a syntax error (`ERROR 1064`), so the phase aborted on every
      apply. Pre-existing, untouched by the transport work, and surfaced by it:
      until this landed no end-to-end apply could succeed.
- [x] `bin/gen-service-accounts` — `query_live_state()`: add a `mysql.db` read
      (`SELECT User, Host FROM mysql.db WHERE Db = '<db>'`) and gate the Phase 3
      revokes on it. The statements fail with `ERROR 1141` (no such grant) on an
      account holding no db-level grant — every role-only account, and every
      account on a re-run, which is also what makes the phase idempotent.
- [x] `doc/system/service-accounts.md` — restate the four-phase list and the
      "Direct-grant drift" note as the two-statement form, and add `mysql.db` to
      the live-state sources the closed-world diff reads.

## Open items

- **Host-side roster is never an option** — shipping `team.ini`/`machines.ini` to
  a host would make the closed-world reconcile read a roster that can go stale
  between deploys, silently revoking a member's access on the next run. **no**.
- **The off-host identity is a privileged account** — the reconcile creates
  users and roles, so an off-host `DBUSER` is root-equivalent: global `CREATE
  USER`/`ALTER USER`/`DROP USER`, `CREATE ROLE`/`DROP ROLE`, `GRANT OPTION`, and
  `SELECT` on `mysql.*` for the live-state diff. The operator creates it, as
  with `replication`; a password, if the consumer wants one, arrives through
  `DBPASS`/`MYSQL_PWD`/`~/.my.cnf` — nothing is stored in the endpoint-only
  section.
- **It must be allow-listed** — Phase 4 drops every undeclared account, so an
  off-host `DBUSER` absent from `$allowlist` is dropped by the run that uses it
  (MariaDB allows dropping the current account, so that run succeeds and the
  *next* one cannot connect). Declaring it is the consumer's job; the CLI must
  not infer an allow-list entry from its own environment, or the drop set would
  stop being a pure function of the declaration and live state.
- **Mode determinism is the caller's job** — ema's local-vs-off-host choice is
  inferred from instance presence, so it needs no flag; the *side* is not
  inferred and this CLI pins `EMA_TARGET=prod` explicitly. Any future caller with
  the same requirement must do the same rather than trust an ambient value.
- **No SSH hop** — the transport adds no second root path into the DB host. The
  operator machine's root SSH stays where it already is (`replica-bootstrap`,
  `gen-firewall`); this CLI does not use it.
- **`gen-grants` / `gen-cert`** — the cert-pinned team-member family is
  untouched; it is a separate auth mode and population (see the unification note
  in `doc/system/service-accounts.md`). `gen-grants` stays a DB-host verb, so
  its `DBUSER=root` prefix stays correct.
- **Dry-run fidelity** — with live state reachable, `-n` prints the complete
  four-phase SQL; the "closed-world set omitted" warning should remain reachable
  only on a genuine transport failure.
- **`doc/system/composer.md`** — expected unchanged: the bin list and the
  `gen-service-accounts` pointer stay valid.
- **Table- and column-level direct grants are not revoked** — Phase 3 clears
  database-level grants only, the level the live read covers (`mysql.db`), so a
  direct grant below the database (`mysql.tables_priv`, `mysql.columns_priv`) on
  the managed database survives the reconcile. **revisit if** a consumer ever
  grants below the database level; widening it means reading those tables in
  `query_live_state()` and gating on them the same way.
