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

Invocation is the same script on either side of the package boundary; only the
path differs — `bin/replica-bootstrap` in this repo, `vendor/bin/` in a
consumer (the `bin` array installs it into the root's `vendor/bin`; see
[composer.md](composer.md)). A consumer runs it **from its repo root**: the
primary's section is read from `etc/reuter.ini` in the working directory.

```bash
bin/replica-bootstrap --primary <db> --replica-host <zerotier-ip> \
    [--dest <remote-dir>] [--dry-run]
```

A consumer substitutes `vendor/bin/replica-bootstrap` and passes its own
primary name and replica IP. There is deliberately no `REUTER_INI` lookup and no
`--reuter-ini` override: `REUTER_INI` is mode-scoped (a dev shell points it at a
sandbox ini that holds no prod section) while this CLI always targets prod
connectivity, so the repo-root file is the only source.

| Flag | Meaning |
|---|---|
| `--primary <db>` | primary database name (the `[<db>]` `etc/reuter.ini` section). |
| `--replica-host <ip>` | replica host ZeroTier IP — the `replication`@<ip> pin and the snapshot destination host. |
| `--dest <dir>` | remote dir on the replica host the snapshot extracts into (default `/root/replica-snapshot-<db>`). |
| `--dry-run` | print the commands without executing them. |

The two address flags are deliberately asymmetric. `--primary` is a *name*: the
`[<db>]` section is looked up, and it supplies the host *and* the
root/unix_socket. `--replica-host` is a literal *IP*, because the replica has
no instance and no section yet — there is nothing to look up — and the value is
used twice: as the `root@<ip>` SSH/scp target and as the `'replication'@'<ip>'`
host pin, which must be the address the primary sees as the replica's client
source. A hostname or ssh alias there would pin the wrong principal. `--dest`
defaults to `/root/replica-snapshot-<db>` — named after the primary, since the
replica's name is not known here.

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
grant, so it belongs to no service-account reconcile file. It is not covered
by the service-account reconcile's drop floor (`root` and `mariadb.sys`
only), so a consumer running that reconcile must declare `replication` in its
`$allowlist` or the next reconcile drops the account.

## The snapshot

The snapshot is a `mariabackup` physical hot backup, `--prepare`d before
shipping so the restore is a direct copy. Its provenance contract is the
binlog file/position the replica resumes from, read from the snapshot's own
backup metadata (`mariadb_backup_info`, or `xtrabackup_info` on older
tooling — the `filename '...'`/`position '...'` fields).

The replica build (`ema create --from-snapshot`) checks that coordinate at
restore — a missing snapshot, or one with no binlog coordinate, aborts. A
wrong-source snapshot is not detectable at restore (MariaDB records no
`server_uuid` in a snapshot), so it fails loudly at the attach step
(`Slave_IO_Running != Yes`) instead.

## Workflow

1. Record the primary's `[<db>]` section in `etc/reuter.ini` (from `ema
   create` output, or `ema values <db>`).
2. Run `bin/replica-bootstrap --primary <db> --replica-host <ip>` (in a
   consumer: `vendor/bin/replica-bootstrap …`) from a dev machine with root SSH
   to both hosts. It creates the transport account and ships the prepared
   snapshot to the replica host's `--dest`.
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
- The replication coordinate is the binlog file/position recorded in the
  snapshot's backup metadata (`mariadb_backup_info`/`xtrabackup_info`); GTID
  resume is a tracked future refinement.
