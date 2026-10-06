# Consumer configuration

Date: 2026-09-20 (committed defaults 2026-10-01)
Scope: how this framework separates public code from private operational data.
The framework owns the mechanism and ships committed templates and consumed
defaults; the consumer owns the private files, keeps them in its own private
repository, and declares which of them the framework must ship to prod
(`DEPLOY_PRIVATE_FILES`). Deploy config (`etc/deploy.conf`) is
deploy-machine-only: the framework sources it locally and replays its
environment to the host, so prod never holds a copy. The framework sources
whatever real `etc/` files it finds and fails loudly when one it needs is
missing.

## What is private data

The public repo ships the mechanism and, for every operational data file,
either a committed template (a copy-me shape) or a committed default (a real
value read as a fallback). The real, machine-specific values are private and
must not enter the public Git history:

| File | Committed in public repo | Private data |
|---|---|---|
| `etc/deploy.conf` | `etc/deploy.conf.template` | project deployment target (paths, the app-user name, cron target); deploy machine only — its values are replayed to hosts as env |
| `etc/dev.conf` | `etc/dev.default.conf` (consumed default) + optional `etc/dev.conf` override | local dev values (the DB username, the TLS client-cert directory); dev machine only — sourced by `init-local-env.sh` and `gen-cert`, never shipped to a host |
| `etc/reuter.ini` | `etc/reuter.ini.template` | per-database connectivity sections (recorded from `ema create`); needed on every prod host |
| `etc/ema.conf` | `etc/ema.default.conf` (consumed default) + optional `etc/ema.conf` override | host-level `ema` config — the `ssl-ca` the instance verifies client certs against; needed only on a host that provisions instances |
| `etc/machines.ini` | `etc/machines.ini.template` | prod ZeroTier IPs + `tag[:name]` roster (dev/deploy machine only) |
| `etc/team.ini` | `etc/team.ini.template` | member identities, hostnames, ZeroTier IPs (dev machine only) |
| `etc/host-hardening.php` | `etc/host-hardening.php.template` | firewall reconcile declaration (`$zerotierRange`, `$tagRules`) for `gen-firewall` (dev/deploy machine only) |
| `etc/hosts` | — (optional) | dev-only name→IP mapping for the consumer's `/etc/hosts` merge and its generated dev ssh aliases (`gen-ssh-config`) |

`reuter.ini` is the only private file **every** prod host needs whatever its
role, so it is the only one a consumer's deploy pipeline always has to deliver —
and it is delivered **whole** (no inner filtering, no section splicing).
`ema.conf` is the second case, and a narrower one: only a host that provisions
instances needs its `ssl-ca`. A consumer using client-cert auth ships the value
as its committed `etc/ema.default.conf` (so it rides with the repo on every
host) and keeps `etc/ema.conf` only for a host that diverges from it; a
consumer with no `ssl-ca` leaves the default's key out entirely. Because
`DEPLOY_PRIVATE_FILES` is one list shipped to every host, a committed default is
the natural home for a host-wide value like `ssl-ca` — it needs no ship step and
no per-host filtering. `deploy.conf` stays on the deploy machine: its values are
the deploy parameters, replayed to the host as environment rather than shipped
as a file. `dev.conf` stays on the dev machine: its values are local dev
parameters (sourced by `init-local-env.sh` and `gen-cert`), never shipped to a
host.
`machines.ini`, `team.ini`, `hosts` and `host-hardening.php` are dev/deploy-time
inputs: `machines.ini` feeds the local deploy roster, `team.ini` feeds
`gen-cert`/`gen-team-accounts`/`gen-service-accounts`, `hosts`
(optional) feeds the consumer's dev `/etc/hosts` merge and its generated ssh
aliases (`gen-ssh-config`), and `host-hardening.php` feeds `gen-firewall`.
None of them belong on a host.

`etc/dev.default.conf` and `etc/ema.default.conf` are **consumed defaults**, not
templates: `init-local-env.sh` sources `etc/dev.default.conf` then the optional
`etc/dev.conf` override, and the DB-layer `ema` CLI reads
`etc/ema.default.conf` then the optional `etc/ema.conf` override. `.template`
stays reserved for the copy-me files.

The dev sandbox's per-instance `var/sandbox/<name>-<GUID>/reuter.ini` is read
by the app layer as well: under `EMA_TARGET=sandbox`, `Database::connectTo`
resolves it by instance name (the schema it serves still comes from the
section's `DBNAME`, defaulting to the header). It is generated, machine-local
data (ema writes it; the consumer git-ignores it), not a private config file —
which is why the dev `.env` carries no `REUTER_INI` and no credentials: the
sandbox is reached as `root` over its own socket.

## The private repo

The recommended home for the real files is a small access-controlled git
repository whose tracked files mirror the consumer's `etc/` operational data:

```text
<consumer-config>/
├── deploy.conf
├── dev.conf           (optional — override over etc/dev.default.conf)
├── machines.ini
├── reuter.ini
├── ema.conf           (optional — override over etc/ema.default.conf: ssl-ca)
├── team.ini
├── hosts              (optional — dev-only hostname→IP mapping)
├── host-hardening.php (optional — firewall reconcile declaration)
└── README.md
```

Its committed content is the single source of truth on every machine that can
reach git — nothing runs on a loose, uncommitted copy. Keep credentials out of
it where possible: private-repo access control does not eliminate the risks of
credentials copied through clones, backups, CI, or developer machines (the
service-account auth policy — passwords vs. certificates — is a deferred
decision; see
`doc/plans/2026-09-09-ema-prod-instance-at-create-manual-reuter.md`).

## Private-file delivery

Getting the private files onto a prod host is the framework's job for the files
the consumer declares in `DEPLOY_PRIVATE_FILES`, and the consumer's job for
everything else. What the framework guarantees on the reading side:

- `deploy` sources `etc/deploy.conf` and reads the roster
  from `etc/machines.ini` as plain files on the dev/deploy machine, and fails
  loudly when either is missing. It replays the sourced `deploy.conf`
  environment to every remote step and ships the files named in
  `DEPLOY_PRIVATE_FILES` into the freshly swapped `etc/`, skipping any name
  that is absent from `etc/` (the consumer's deploy wrapper confirms the
  absence before running this CLI).
- `bin/pf-provision.sh`, `bin/gen-env`, `bin/cron-manifest` and `bin/db-check`
  read the real files the same way: `deploy.conf` is sourced only when present
  (otherwise the replayed environment supplies the values); no fetching, no
  symlink creation, no "shadowed file" warnings.
- `bin/gen-cert`, `bin/gen-team-accounts`, `bin/gen-ssh-config`, `bin/gen-firewall`,
  `bin/replica-bootstrap` and `bin/tmux-remote` read their private inputs from
  `etc/` and fail loudly when one is absent (`gen-ssh-config` takes
  `--hosts <path>` for a mapping kept elsewhere; `tmux-remote` needs the deploy
  machine's `etc/deploy.conf` for the remote-shell paths; `replica-bootstrap`
  reads `etc/reuter.ini` from the working directory and takes no environment
  override).
- The DB-layer `ema` CLI (a framework dependency) reads the host-level
  `etc/ema.default.conf` (then the optional `etc/ema.conf` override) from the
  repo root on a host that provisions instances; an absent key means no
  `ssl-ca` line, not an error.

## Production (no git)

Prod hosts have no git and no consumer-config tooling, so delivery runs from the
deploy machine, which has both. `deploy` swaps the repo directory on
every deploy, which wipes `etc/`, so the real private files must be restored on
the host **before** anything reads them. **`DEPLOY_PRIVATE_FILES`** (see
`etc/deploy.conf.template`) covers that: it names the `etc/`-relative files
the framework ships — tarred from the deploy machine's `etc/` and extracted
into the freshly swapped `etc/` in one post-swap step, before anything sources
them. The consumer materializes `etc/` first (its own dev-init/fetch step); for
a host that only needs `reuter.ini`, that is the whole story. A host-wide value
such as `ema.conf`'s `ssl-ca` does not need shipping at all when the consumer
commits it as `etc/ema.default.conf` — the swap carries it along with the rest
of the repo.

`deploy.conf` is **not** shipped. Its values are replayed as environment to
every remote step, so the host never needs a copy; a consumer that commits a
real `etc/deploy.conf` still works (the host-side scripts source the file only
when present), but committing it is optional.

```bash
# deploy machine, inside nix develop, on main:
deploy all   # full deploy; ships DEPLOY_PRIVATE_FILES, replays deploy.conf env
```

## Security boundary

The real security boundary is access control on the private repository (and on
the production systems). Repository privacy must be enforced by authentication
and authorization, not by hiding the private repo's identity.
