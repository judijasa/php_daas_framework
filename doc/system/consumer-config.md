# Consumer configuration

Date: 2026-09-20
Scope: how this framework separates public code from private operational data.
The framework owns the mechanism and ships committed templates; the consumer
owns the private files, keeps them in its own private repository, and is
responsible for putting them in place. The framework never fetches, ships or
injects private config — it sources the real files it finds in `etc/` as plain
files and fails loudly when one is missing.

## What is private data

The public repo ships the mechanism and committed templates for every
operational data file. The real values are private and must not enter the
public Git history:

| File | Public template | Private data |
|---|---|---|
| `etc/deploy.conf` | `etc/deploy.conf.template` | project deployment target (paths, the app-user name, cron target); needed on every prod host |
| `etc/reuter.ini` | `etc/reuter.ini.template` | per-database connectivity sections (recorded from `ema create`); needed on every prod host |
| `etc/machines.ini` | `etc/machines.ini.template` | prod ZeroTier IPs + `tag[:name]` roster (dev/deploy machine only) |
| `etc/team.ini` | `etc/team.ini.template` | member identities, hostnames, ZeroTier IPs (dev machine only) |
| `etc/host-hardening.php` | `etc/host-hardening.php.template` | firewall reconcile declaration (`$zerotierRange`, `$cloudTest`, `$tagRules`) for `gen-firewall` (dev/deploy machine only) |
| `etc/hosts` | — (optional) | dev-only name→IP mapping for the consumer's `/etc/hosts` merge and its generated dev ssh aliases (`gen-ssh-config`) |

`deploy.conf` and `reuter.ini` are the only private files a prod host needs, so
they are the only ones a consumer's deploy pipeline ever has to deliver — and
they are delivered **whole** (no inner filtering, no section splicing).
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

## Consumer-owned delivery

Getting the private files onto a machine is the consumer's job. The framework
neither knows nor cares how it is done — a git clone plus symlinks into `etc/`,
a `git archive` extraction, `scp`, or the consumer's own script all work. What
the framework guarantees is the reading side:

- `bin/pf-deploy.sh` sources `etc/deploy.conf` and reads the `[prod]` roster
  from `etc/machines.ini` as plain files on the dev/deploy machine, and fails
  loudly when either is missing.
- `bin/pf-provision.sh`, `bin/gen-env`, `bin/cron-manifest`, `bin/db-check`
  and `bin/replica-bootstrap` read the real files the same way: no fetching, no
  symlink creation, no "shadowed file" warnings.
- `bin/gen-cert`, `bin/gen-grants`, `bin/gen-ssh-config` and `bin/gen-firewall`
  read their private inputs from `etc/` and fail loudly when one is absent
  (`gen-ssh-config` takes `--hosts <path>` for a mapping kept elsewhere).

### A consumer-side convention: `.private-source`

`.private-source.example` documents the pointer shape consumers are encouraged
to share: an untracked, git-ignored `.private-source` at the repo root naming
the private repo's git URL (+ optional ref), fetched on demand into the
git-ignored `var/private-data`. The framework does not read that file — it is
the consumer's own dev-init/deploy tooling that fetches and injects.

## Production (no git)

Prod hosts have no git and no consumer-config tooling, so delivery runs from the
deploy machine, which has both. `bin/pf-deploy.sh` swaps the repo directory on
every deploy, which wipes `etc/`, so the real private files must be restored on
the host **before** anything sources them. The framework's single hook for that
is `DEPLOY_PRE_PROVISION_CMD` (optional; see `etc/deploy.conf.template`):

1. The consumer ships its private files to a stable per-app directory on the
   host (outside `DEPLOY_TARGET_DIR`, which is swapped on every deploy) with its
   own tooling — the framework ships nothing. `DEPLOY_PRIVATE_CONFIG_DIR` is a
   documented example variable for that directory; it is consumer-owned, not
   framework machinery, and no framework script reads it.
2. `bin/pf-deploy.sh` runs `DEPLOY_PRE_PROVISION_CMD` on the host as root, in
   the repo root, right after the repo swap + `composer install` and before
   `pf-provision.sh` and the built-in server steps. The deploy machine's
   `deploy.conf` environment is replayed for the hook, so it can reference any
   `DEPLOY_*` value (including `DEPLOY_PRIVATE_CONFIG_DIR`) without the host
   having a `deploy.conf` of its own yet.
3. The hook materializes the real `etc/deploy.conf` and `etc/reuter.ini` (the
   latter at `DEPLOY_REUTER_INI`). `pf-deploy.sh` then fails loudly if
   `etc/deploy.conf` is still missing, so a consumer that commits its real
   `deploy.conf` and needs no hook also works.

```bash
# deploy machine, inside nix develop, on main:
bin/pf-deploy.sh   # full deploy; the host's DEPLOY_PRE_PROVISION_CMD restores etc/
```

## Security boundary

The `.private-source` pointer provides information separation only. The real
security boundary is access control on the private repository (and on the
production systems). Repository privacy must be enforced by authentication and
authorization, not by hiding the private repo's identity.
