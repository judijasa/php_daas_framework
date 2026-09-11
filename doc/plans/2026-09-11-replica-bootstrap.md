# Read-only replica bootstrap helper — Plan & Progress

Date: 2026-09-11
Repos: php_daas_framework (this repo).

## Decision

Add a generic, operator-run `bin/replica-bootstrap` helper that performs the
one-time transport bootstrap for a read-only replica: it creates a
passwordless, host-pinned `replication` account on the primary and ships a
consistent snapshot to the replica host. The helper is generic — it knows no
consumer service-account names beyond the fixed `replication` transport
account, and no database names beyond the primary section it is told to read.

The replica host never holds root on the primary: the account and snapshot
are prepared beforehand by an operator with root SSH to both hosts, and the
consumer's replica build only restores the shipped snapshot and starts
replication. The account is an instance-level `GRANT REPLICATION SLAVE ON
*.*` (not a per-database grant), so it belongs to no service-account
reconcile file. The snapshot is a `mariabackup` physical hot backup, prepared
before shipping, so its provenance (`xtrabackup_binlog_info` binlog/GTID
coordinate + the source `server_uuid`) is the contract the replica build
verifies at restore.

## Changes

### php_daas_framework (this repo)

- [x] `bin/replica-bootstrap` (new) — generic helper: `--primary <db>` +
      `--replica-host <ip>`; creates `replication`@<ip> (passwordless,
      `REPLICATION SLAVE`), takes + prepares a `mariabackup` snapshot, ships
      it to the replica host (relayed over root SSH). `--dry-run` prints the
      commands.
- [x] `composer.json` — `bin/replica-bootstrap` added to the `bin` array.
- [x] `doc/system/replica-bootstrap.md` (new) — operator procedure + contract
      (account shape, snapshot provenance, workflow).
- [x] `README.md` — `bin/replica-bootstrap` in the Distribution list, pointing
      at the doc.
- [x] `bin/db-check` — verified unchanged: it already iterates every
      `db:<name>` tag and every `reuter.ini` section, so two `db:` names work
      with no change.

## Open items

- **Snapshot tool** — `mariabackup` (physical, GTID via
  `xtrabackup_binlog_info`) is the default; a logical `mysqldump
  --master-data` is the fallback shape if a physical backup proves too heavy.
  Undecided; no alternative is implemented yet.
- **Coordinate style** — binlog position vs. GTID is undecided; GTID is
  preferred (stable identity; a foreign snapshot's GTID domain fails
  `START SLAVE`).
