# Read-only replica bootstrap

Date: 2026-09-11
Scope: the one-time transport bootstrap for a read-only replica — the step
that runs **before** a replica instance is provisioned. The framework owns
the mechanism (`bin/replica-bootstrap`); the consumer owns the replica policy
(the primary/replica database names and host roster, the replica's own
provisioning, and the read routing).

## Why it is separate

A read-only replica is seeded from a consistent snapshot of the primary and
then follows the primary's binlog over a low-privilege transport account.
The replica host must never hold root on the primary, so the transport
account and the initial snapshot are prepared **once, beforehand**, by an
operator with root SSH to both hosts — never by the replica's own
provisioning.

`replica-bootstrap` is that one-time step. It:

1. creates a passwordless, host-pinned `replication` transport account on the
   primary (`CREATE USER 'replication'@'<replica-ip>' IDENTIFIED BY ''` +
   `GRANT REPLICATION SLAVE ON *.*` — an instance-level/global transport
   grant, not a per-database grant);
2. takes a consistent snapshot of the primary (`mariabackup`, prepared) and
   ships it to the replica host.

The consumer's replica provisioning then restores the shipped snapshot and
starts replication from the recorded coordinate — it does not recreate the
transport account or take the snapshot itself.

## Inputs

`replica-bootstrap` runs from a dev machine with root SSH to both the primary
and replica hosts (ZeroTier). It reads the primary's connectivity from the
consumer's `etc/reuter.ini` section — `SERVER` (the primary host, also the
SSH target) and `MYSQL_UNIX_PORT` (the instance's root/unix_socket). The
replica's own section is not needed yet: its instance does not exist until it
is provisioned.

```bash
replica-bootstrap --primary <db> --replica-host <zerotier-ip> \
    [--dest <remote-dir>] [--reuter-ini <path>] [--dry-run]
```

| Flag | Meaning |
|---|---|
| `--primary <db>` | primary database name (the `[<db>]` `etc/reuter.ini` section). |
| `--replica-host <ip>` | replica host ZeroTier IP — the `replication`@<ip> pin and the snapshot destination host. |
| `--dest <dir>` | remote dir on the replica host the snapshot extracts into (default `/root/replica-snapshot-<db>`). |
| `--reuter-ini <path>` | reuter.ini to read (default `$REUTER_INI` or `etc/reuter.ini`). |
| `--dry-run` | print the commands without executing them. |

## The replication account

The account is fixed and generic — the framework does not know any consumer
service-account name beyond `replication`:

```sql
CREATE USER IF NOT EXISTS 'replication'@'<replica-ip>' IDENTIFIED BY '';
ALTER USER 'replication'@'<replica-ip>' IDENTIFIED BY '';
GRANT REPLICATION SLAVE ON *.* TO 'replication'@'<replica-ip>';
```

It is passwordless (empty password — the security boundary is the host pin
plus the transport network) and host-pinned to the replica host, so only the
replica may connect as it. It is an instance-level grant, not a per-database
grant, so it belongs to no service-account reconcile file.

## The snapshot

The snapshot is a `mariabackup` physical hot backup, `--prepare`d before
shipping so the restore is a direct copy. Its provenance contract is the
`xtrabackup_binlog_info` binlog file/position coordinate the replica resumes
from.

The replica build (`ema create --from-snapshot`) checks that coordinate at
restore — a missing snapshot, or one with no binlog coordinate, aborts. A
wrong-source snapshot is not detectable at restore (MariaDB records no
`server_uuid` in a snapshot), so it fails loudly at the attach step
(`Slave_IO_Running != Yes`) instead.

## Workflow

1. Record the primary's `[<db>]` section in `etc/reuter.ini` (from `ema
   create` output, or `ema values <db>`).
2. Run `replica-bootstrap` from a dev machine with root SSH to both hosts.
3. Provision the replica: an `srv/<name>-<GUID>` package whose `default.php`
   declares `$db['type']='replica'` and `$db['replica_of']=<primary>` (no
   `$dependencies`/`upgrade.sql`), built with
   `ema create srv/<name>-<GUID> --from-snapshot <dest>` — ema restores the
   shipped snapshot and attaches replication from the recorded coordinate
   (`read_only=1`, `replicate-rewrite-db = <primary>-><replica>`).

The helper is re-runnable: the account creation is idempotent, and the
snapshot is rebuilt and re-shipped on every run.

## Notes

- `replica-bootstrap` is operator-run and one-time; it is not a deploy or
  cron step.
- `mariabackup` is the only supported snapshot; a logical
  `mysqldump --master-data` dump is not accepted by `--from-snapshot`.
- The replication coordinate is the binlog file/position recorded in
  `xtrabackup_binlog_info`; GTID resume is a tracked future refinement.
