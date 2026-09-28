# Service-account reconcile over the host's own ssh root — Plan & Progress

Date: 2026-09-28
Repos: php_daas_framework (this repo).

## Decision

Supersedes the transport decision of
`doc/plans/2026-09-27-service-accounts-remote-reconcile.md` (TCP as `DBUSER`);
everything else in that plan stands.

`gen-service-accounts` has two homes it cannot reconcile: it must plan where the
roster is (the operator machine — `etc/team.ini`, `etc/machines.ini`, `srv/*`)
and execute where the database identity is (the DB host — the section's socket,
root via `unix_socket`). The 2026-09-27 plan bridged them with ema's off-host
transport, TCP at the section's `SERVER`/`PORT` as an account the operator
exports in `DBUSER`. It works, but it buys that bridge with an account nobody
else needs: root-equivalent on the TCP port (global `CREATE USER`/`ALTER
USER`/`DROP USER`, `CREATE ROLE`/`DROP ROLE`, `GRANT OPTION`, `SELECT` on
`mysql.*`), created by the operator, and kept out of Phase 4 only by a
hand-maintained `$allowlist` entry — forget the entry and the run drops the very
account it is connected as, which the *next* run discovers.

The CLI bridges the two itself instead, the way this repo's other operator verbs
already reach a host: `ssh root@<host>`, and run the **host's own** `ema` from the
deployed repo root. On the host that call takes ema's local path — the section's
`MYSQL_UNIX_PORT` socket as root — which is the same run the CLI performed back
when it lived on the DB host. Nothing is guessed: the host is the one carrying
the database's `db:<name>` `[prod]` token (the framework's one-to-one server
mapping, the token the roster already means), and the deployed repo root comes
from the consumer's `DEPLOY_TARGET_DIR` — the same `etc/deploy.conf` every other
CLI sources.

../ema's objection to a root-over-SSH transport — an inferred remote root path is
a second, arbitrary way into the DB host — is scoped to ema, where a *generic*
transport would have to infer it. Here there is nothing to infer: the CLI does
not reach the database, it reaches a host it already names, with a credential the
operator machine already holds (`root` SSH to prod hosts is what `pf-deploy.sh`,
`gen-firewall` and `replica-bootstrap` use), and the database identity stays the
host's own root over its own socket. ema is untouched: its `mariadb` verb keeps
both of its paths for every other caller.

So the reconcile carries no database identity at all — no `DBUSER` to export, no
password to source, no privileged account on the TCP port, no `$allowlist` entry
to remember. `EMA_TARGET=prod` stays pinned on the invocation, now inside the
remote command.

## Topology

    operator machine                    database host
    ────────────────                    ─────────────
    etc/team.ini      ┐
    etc/machines.ini  ┤ plan            (roster never leaves this machine)
    srv/*.roles-*     ┘
    etc/deploy.conf   ──► DEPLOY_TARGET_DIR
                      │
                      └ ssh root@<host carrying db:<name>> ──► cd <DEPLOY_TARGET_DIR>
                                                               && EMA_TARGET=prod
                                                               ./vendor/bin/ema mariadb <db>
                                                               (socket, root: host-local)
    live state  ◄──────────────────────────────────────────────┘

## Changes

### php_daas_framework (this repo)

- [x] `bin/gen-service-accounts` — `main()`: resolve the target host from the
      `db:<name>` `[prod]` token, with `resolve_source_hosts()` (the grammar the
      tag sources already use); one database tagged on more than one host is a
      config error rather than a guess. No token — the DB host itself carries no
      roster — runs locally, as before.
- [x] `bin/gen-service-accounts` — new `deploy_target_dir()`: read the
      consumer's `DEPLOY_TARGET_DIR` from `etc/deploy.conf`, sourced as a plain
      file like this repo's other CLIs (no second shell parser). Resolved before
      the first connection, so a missing `etc/deploy.conf` fails loudly.
- [x] `bin/gen-service-accounts` — new `ema_command()`: build the invocation once
      for both sides — locally `EMA_TARGET=prod <ema> mariadb <db>`, remotely
      `ssh root@<host> 'cd <DEPLOY_TARGET_DIR> && EMA_TARGET=prod
      ./vendor/bin/ema mariadb <db>'`. The remote form quotes the whole remote
      command for the local shell, so the SQL argument is quoted once inside it.
- [x] `bin/gen-service-accounts` — `run_query()` / `query_live_state()` /
      `apply_sql()`: take the transport instead of resolving `ema` themselves,
      and keep the SQL-file redirect **local** (`... < file`), so over ssh it
      feeds the remote command's stdin instead of naming a path that exists only
      here.
- [x] `bin/gen-service-accounts` — header note, `--help` and the live-state
      guard: the operator-machine + `ssh root@<host>` model, with the failing
      host named in the message.
- [x] `doc/system/service-accounts.md` — replace the `DBUSER` transport
      paragraph with the ssh-root model, and restate the "off-host identity" note
      as "the reconcile carries no database identity of its own".

## Open items

- **A host-side run plans nothing** — a host carries no roster, so there is no
  `db:<name>` token to resolve. That is the declaration inputs' pre-existing
  fail-open shape (out of scope on 2026-09-27, still out of scope here): the CLI
  reports the empty plan instead of guessing a target.
- **A stale `DEPLOY_TARGET_DIR` fails loudly** — the path is consumer config, and
  a wrong one is an ssh `cd` failure, never a silent local fallback.
- **The host must have been deployed** — its `vendor/bin/ema` arrives with
  `composer install` at deploy time. Same prerequisite as `tmux-remote`.
- **`gen-grants` / `gen-cert`** — untouched: the cert-pinned family stays a
  DB-host verb with its own `DBUSER=root` prefix.
- **One ssh connection per query and per phase** — up to six per run, no
  `ControlMaster`, no batched reads. Fine for an operator verb; revisit only if a
  consumer's link makes it painful.
- **`-n/--dry-run` fidelity** — unchanged from 2026-09-27: live state is read
  over the same transport, so `-n` prints the complete four-phase SQL, and the
  "closed-world set omitted" warning stays reachable only on a genuine transport
  failure.
