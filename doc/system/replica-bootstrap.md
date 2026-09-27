# Read-only replica bootstrap

Date: 2026-09-11
Scope: the one-time transport bootstrap for a read-only replica — the step
that runs **before** a replica instance is provisioned. The framework owns
the mechanism (`bin/replica-bootstrap`); the consumer owns the replica policy
(the primary/replica database names and host roster, the replica's own
provisioning, and the read routing).

## Quick setup

```bash
# primary: enable binary logging (log_bin); install the MariaDB client + a
#          version-matched MariaDB backup package
# primary: record its [<db>] section in etc/reuter.ini (from ema create, or ema values <db>)

# dev machine, repo root, with root SSH to both hosts
bin/replica-bootstrap --primary <db> --replica-host <ip>

# replica host: the srv/<name>-<GUID> package (type=replica, replica_of=<db>)
ema create srv/<name>-<GUID> --from-snapshot <dest>
```

Hand-run fallback — the same transport account and snapshot, prepared by hand
without `bin/replica-bootstrap`:

```bash
# primary: create the transport account (see "The replication account")
#   CREATE USER IF NOT EXISTS 'replication'@'<ip>' IDENTIFIED BY '';
#   ALTER USER 'replication'@'<ip>' IDENTIFIED BY '';
#   GRANT REPLICATION SLAVE ON *.* TO 'replication'@'<ip>';

# primary: take + prepare the snapshot (socket = the primary's MYSQL_UNIX_PORT)
mariadb-backup --backup --target-dir=<dest> --user=root --socket=<MYSQL_UNIX_PORT>
mariadb-backup --prepare --target-dir=<dest>

# replica host
ema create srv/<name>-<GUID> --from-snapshot <dest>
```

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
restore — a missing snapshot, or one with no binlog coordinate, aborts. This
helper refuses a primary with `log_bin` disabled before taking the snapshot, so
a coordinate-less snapshot cannot be produced by this run. A wrong-source
snapshot is not detectable at restore (MariaDB records no `server_uuid` in a
snapshot), so it fails loudly at the attach step (`Slave_IO_Running != Yes`)
instead.

## Host requirements

The run checks its host prerequisites over SSH **before** it creates or changes
anything, so a missing tool aborts with an `ERROR:` line and leaves no partial
state — the run is safe to repeat once the host is fixed. None of the
prerequisites is installed by the framework's host provisioning, which only
ships the `mariadb@.service` template unit.

- **Primary** — a MariaDB client (`mariadb`, or `mysql` on older packaging),
  which runs the transport-account DDL, a physical backup tool (`mariabackup`,
  or `mariadb-backup` on newer packaging), which produces the snapshot, and
  **binary logging enabled** (`log_bin`) — the snapshot's replication
  coordinate is the primary's binlog file/position, so a primary without
  `log_bin` produces a snapshot the replica build refuses to restore. The
  backup tool must be version-matched to the running server; it ships in the
  MariaDB backup package, so install the one matching the server (a
  consumer's host-setup docs carry the concrete package for their distro).
- **Dev machine** — root SSH to both the primary and the replica host
  (ZeroTier).

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
   (`read_only=1`, `replicate-rewrite-db = <primary>-><replica>`). A replica
   may also opt into verifying the primary's server certificate with
   `$db['replica_ssl_verify_server_cert'] = true` — replica-only and default
   off (the primary's certificate is the self-signed one until a consumer
   provisions a CA).

   The build's own contract — the package keys, the gates it enforces — is
   ema's
   [doc/system/replica-bootstrap.md](https://github.com/judijasa/ema/blob/main/doc/system/replica-bootstrap.md),
   which also carries the hand-run fallback: the same transport account and
   snapshot, prepared by hand, without this CLI.

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
