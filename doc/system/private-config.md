# Private configuration repository

Date: 2026-09-08
Scope: how this framework separates public code from private operational data
using a `.private-source` pointer, the `fetch-private-data` injector, and the
`deploy-private-config` prod shipper.

## What is private data

The public repo ships the mechanism and committed templates for every
operational data file. The real values are private and must not enter the
public Git history:

| File | Public template | Private data | Ships to prod? |
|---|---|---|---|
| `etc/deploy.conf` | `etc/deploy.conf.template` | project deployment target (paths, the app-user name, cron target) | **yes — ships to prod with `reuter.ini`** |
| `etc/reuter.ini` | `etc/reuter.ini.template` | per-database connectivity sections (recorded from `ema create`) | **yes — ships to prod with `deploy.conf`** |
| `etc/machines.ini` | `etc/machines.ini.template` | prod ZeroTier IPs + `tag[:name]` roster | no (deploy/dev-time only) |
| `etc/team.ini` | `etc/team.ini.template` | member identities, hostnames, ZeroTier IPs | no (dev-only) |
| `etc/host-hardening.php` | `etc/host-hardening.php.template` | firewall reconcile declaration (`$zerotierRange`, `$cloudTest`, `$tagRules`) for `gen-firewall` | no (deploy/dev-time only) |

A consumer may also keep an optional `etc/hosts` (a dev-only name→IP mapping
for its servers); `fetch-private-data` wires it into `etc/` like
`machines.ini`/`team.ini` when the private repo provides it. It is the single
source for both the consumer's `/etc/hosts` merge and its generated dev ssh
aliases (`doc/system/ssh-config.md`).

`etc/deploy.conf` is now private data too (the project deployment target:
paths, the app-user name, the cron target) — it ships to prod with
`reuter.ini`, so the public repo keeps only `etc/deploy.conf.template`. The
`reuter.ini` connectivity sections (and any `<ACCOUNT>_PASSWORD` keys the
consumer's service-user provisioning writes into them) are private data and
live only in the private repo, never in the public history.

`deploy.conf` and `reuter.ini` are the only private files a prod host needs,
so they are the only ones that ever leave the private repo for a host — and
they ship **whole** (no inner filtering, no section splicing). `machines.ini`,
`team.ini`,
`hosts` and `host-hardening.php` are dev/deploy-time inputs: `machines.ini`
feeds the local deploy roster, `team.ini` feeds
`gen-cert`/`gen-grants`/`gen-service-accounts`/`init-local-env`, `hosts`
(optional) feeds the consumer's dev `/etc/hosts` merge and its generated ssh
aliases (`gen-ssh-config`), and `host-hardening.php` feeds `gen-firewall`.
None of them reach prod.

## The private repo

The private repo is a small access-controlled git repository whose tracked
files mirror the consumer's `etc/` operational data:

```text
<private-config>/
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

## .private-source

Each dev/deploy machine holds an untracked, git-ignored `.private-source` file
that points at the private repo. It never discloses the private repo's hosting
provider or URL in the public history (it is git-ignored).

Copy the committed `.private-source.example` to `.private-source` and set the
one retrieval mechanism — a git URL (+ optional ref):

```ini
PRIVATE_DATA_GIT=git@example.com:team/app-private-config.git
PRIVATE_DATA_REF=main
```

A present `.private-source` that sets no `PRIVATE_DATA_GIT` is an error, not a
silent skip. An absent `.private-source` is a no-op on dev (the public repo
stays fully functional without private data); on prod — no git, no
`.private-source` — the stable per-app dir is resolved from
`DEPLOY_PRIVATE_CONFIG_DIR` instead.

## fetch-private-data

```bash
fetch-private-data [target-dir]   # default: $PWD
```

`fetch-private-data` reads `.private-source` and injects the private files
into `etc/` **as symlinks**. It resolves the source in one of two ways:

1. `.private-source` present → the on-demand clone/fetch into the git-ignored
   `var/private-data` (dev/deploy machines). `reuter.ini` is required, and so
   is `deploy.conf` unless the repo carries its own committed copy;
   `machines.ini`/`team.ini`/`hosts`/`host-hardening.php` are wired only when
   the source provides them (dev/deploy).
2. `.private-source` absent → a no-op, unless `DEPLOY_PRIVATE_CONFIG_DIR`
   (passed in the environment by pf-deploy.sh, or from the already-injected
   `etc/deploy.conf`) names a stable dir that exists — then it links
   `deploy.conf` and `reuter.ini` from there. This is the prod path.

Injection is a symlink, never a copy: `etc/<f>` points into the source, so a
later run refreshes the data through the link. The wire invariant per
destination:

- an up-to-date link (already pointing at the source) is kept;
- a stale or dangling link is re-pointed at the source;
- a real file at `etc/<f>` **shadows** the private data instead — it is
  reported loudly, never overwritten (that silent skip is how a machine ends
  up running stale private config while believing it is current).

A missing `reuter.ini` in the resolved source aborts (the app cannot resolve
a database without it), and so does a missing `deploy.conf` unless the repo
carries its own committed copy (the deploy flow sources it).

`bin/pf-deploy.sh`, `bin/deploy-private-config`, the `make dev-init` target
(via `bin/dev/init-local-env.sh`), and the dev shell entry
(`bin/dev/pf-shell-enter.sh`) call `fetch-private-data` before they read the
private files, so the private data is present whenever a `.private-source` is
configured.

## Production (no git)

Prod hosts have no git and hold no `.private-source`. Delivery is a two-step
split between the deploy machine (which has git) and the host (which has the
stable per-app private dir):

1. **`bin/deploy-private-config`** (deploy machine) ships `deploy.conf` and
   `reuter.ini` — whole, from the private repo's committed content via
   `git archive <ref>` — to the stable per-app dir named by
   `etc/deploy.conf`'s `DEPLOY_PRIVATE_CONFIG_DIR` on each `[prod]` host. It
   ships **nothing else**: `machines.ini`, `team.ini`, `hosts` and
   `host-hardening.php` are never copied to a host. It reads the `[prod]`
   roster from `etc/machines.ini` locally; `machines.ini` is never shipped.

2. **`bin/pf-deploy.sh`**, as a built-in step after the repo swap (before
   `pf-provision.sh` and the `gen-env`/`db-check` server steps), runs
   `fetch-private-data` on the remote with `DEPLOY_PRIVATE_CONFIG_DIR` in the
   environment, which links the stable dir's `deploy.conf` and `reuter.ini`
   into the freshly swapped `etc/`.

Because the stable dir lives outside `DEPLOY_TARGET_DIR` (which is swapped on
every deploy), the private file survives deploys untouched; only the symlink
in `etc/` is recreated. Prod therefore runs committed config only: the
committed-only guarantee comes from the deploy machine's `git archive`, not
from anything prod-side.

```bash
# deploy machine, inside nix develop, on main:
bin/deploy-private-config          # ship deploy.conf + reuter.ini (whole) to every [prod] host
bin/pf-deploy.sh                   # full deploy; links deploy.conf + reuter.ini into etc/ on each host
```

## Security boundary

The `.private-source` pointer provides information separation only. The real
security boundary is access control on the private repository (and on the
production systems). Repository privacy must be enforced by authentication and
authorization, not by hiding the private repo's identity.
