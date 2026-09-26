# Consumer configuration

Date: 2026-09-20
Scope: how this framework separates public code from private operational data.
The framework owns the mechanism and ships committed templates; the consumer
owns the private files, keeps them in its own private repository, and declares
which of them the framework must ship to prod (`DEPLOY_PRIVATE_FILES`). Deploy
config (`etc/deploy.conf`) is deploy-machine-only: the framework sources it
locally and replays its environment to the host, so prod never holds a copy.
The framework sources whatever real `etc/` files it finds and fails loudly when
one it needs is missing.

## What is private data

The public repo ships the mechanism and committed templates for every
operational data file. The real values are private and must not enter the
public Git history:

| File | Public template | Private data |
|---|---|---|
| `etc/deploy.conf` | `etc/deploy.conf.template` | project deployment target (paths, the app-user name, cron target); deploy machine only — its values are replayed to hosts as env |
| `etc/reuter.ini` | `etc/reuter.ini.template` | per-database connectivity sections (recorded from `ema create`); needed on every prod host |
| `etc/machines.ini` | `etc/machines.ini.template` | prod ZeroTier IPs + `tag[:name]` roster (dev/deploy machine only) |
| `etc/team.ini` | `etc/team.ini.template` | member identities, hostnames, ZeroTier IPs (dev machine only) |
| `etc/host-hardening.php` | `etc/host-hardening.php.template` | firewall reconcile declaration (`$zerotierRange`, `$tagRules`) for `gen-firewall` (dev/deploy machine only) |
| `etc/hosts` | — (optional) | dev-only name→IP mapping for the consumer's `/etc/hosts` merge and its generated dev ssh aliases (`gen-ssh-config`) |

`reuter.ini` is the only private file a prod host needs, so it is the only one
a consumer's deploy pipeline ever has to deliver — and it is delivered **whole**
(no inner filtering, no section splicing). `deploy.conf` stays on the deploy
machine: its values are the deploy parameters, replayed to the host as
environment rather than shipped as a file.
`machines.ini`, `team.ini`, `hosts` and `host-hardening.php` are dev/deploy-time
inputs: `machines.ini` feeds the local deploy roster, `team.ini` feeds
`gen-cert`/`gen-grants`/`gen-service-accounts`/`init-local-env`, `hosts`
(optional) feeds the consumer's dev `/etc/hosts` merge and its generated ssh
aliases (`gen-ssh-config`), and `host-hardening.php` feeds `gen-firewall`.
None of them belong on a host.

## The private repo

The recommended home for the real files is a small access-controlled git
repository whose tracked files mirror the consumer's `etc/` operational data:

```text
<consumer-config>/
├── deploy.conf
├── machines.ini
├── reuter.ini
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

- `bin/pf-deploy.sh` sources `etc/deploy.conf` and reads the `[prod]` roster
  from `etc/machines.ini` as plain files on the dev/deploy machine, and fails
  loudly when either is missing. It replays the sourced `deploy.conf`
  environment to every remote step and ships the files named in
  `DEPLOY_PRIVATE_FILES` into the freshly swapped `etc/`.
- `bin/pf-provision.sh`, `bin/gen-env`, `bin/cron-manifest` and `bin/db-check`
  read the real files the same way: `deploy.conf` is sourced only when present
  (otherwise the replayed environment supplies the values); no fetching, no
  symlink creation, no "shadowed file" warnings.
- `bin/gen-cert`, `bin/gen-grants`, `bin/gen-ssh-config`, `bin/gen-firewall`,
  `bin/replica-bootstrap` and `bin/tmux-remote` read their private inputs from
  `etc/` and fail loudly when one is absent (`gen-ssh-config` takes
  `--hosts <path>` for a mapping kept elsewhere; `tmux-remote` needs the deploy
  machine's `etc/deploy.conf` for the remote-shell paths; `replica-bootstrap`
  reads `etc/reuter.ini` from the working directory and takes no environment
  override).

### A consumer-side convention: `.private-source`

`.private-source.example` documents the pointer shape consumers are encouraged
to share: an untracked, git-ignored `.private-source` at the repo root naming
the private repo's git URL (+ optional ref), fetched on demand into the
git-ignored `var/private-data`. The framework does not read that file — it is
the consumer's own dev-init tooling that fetches and materializes `etc/` before
`deploy` ships `DEPLOY_PRIVATE_FILES`.

## Production (no git)

Prod hosts have no git and no consumer-config tooling, so delivery runs from the
deploy machine, which has both. `bin/pf-deploy.sh` swaps the repo directory on
every deploy, which wipes `etc/`, so the real private files must be restored on
the host **before** anything reads them. **`DEPLOY_PRIVATE_FILES`** (see
`etc/deploy.conf.template`) covers that: it names the `etc/`-relative files
the framework ships — tarred from the deploy machine's `etc/` and extracted
into the freshly swapped `etc/` in one post-swap step, before anything sources
them. The consumer materializes `etc/` first (its own dev-init/fetch step); for
a host that only needs `reuter.ini`, that is the whole story.

`deploy.conf` is **not** shipped. Its values are replayed as environment to
every remote step, so the host never needs a copy; a consumer that commits a
real `etc/deploy.conf` still works (the host-side scripts source the file only
when present), but committing it is optional.

```bash
# deploy machine, inside nix develop, on main:
bin/pf-deploy.sh   # full deploy; ships DEPLOY_PRIVATE_FILES, replays deploy.conf env
```

## Security boundary

The `.private-source` pointer provides information separation only. The real
security boundary is access control on the private repository (and on the
production systems). Repository privacy must be enforced by authentication and
authorization, not by hiding the private repo's identity.
