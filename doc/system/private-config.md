# Private configuration repository

Date: 2026-09-08
Scope: how this framework separates public code from private operational data
using a `.private-source` pointer and the `fetch-private-data` CLI.

## What is private data

The public repo ships the mechanism and committed templates for every
operational data file. The real values are private and must not enter the
public Git history:

| File | Public template | Private data |
|---|---|---|
| `etc/machines.ini` | `etc/machines.ini.template` | prod ZeroTier IPs + `tag[:name]` roster |
| `etc/reuter.ini` | `etc/reuter.ini.template` | per-database connectivity sections (recorded from `ema create`) |
| `etc/team.ini` | `etc/team.ini.template` | member identities, hostnames, ZeroTier IPs |

`etc/deploy.conf` stays committed: it is project-static (paths, the app-user
name — no secrets, identical on every prod host), so it is a public interface,
not private data. The `reuter.ini` connectivity sections (and any
`<ACCOUNT>_PASSWORD` keys the consumer's service-user provisioning writes into
them) are private data and live only in the private repo, never in the public
history.

## The private repo

The private repo is a small access-controlled git repository whose tracked
files mirror the consumer's `etc/` operational data:

```text
<private-config>/
├── machines.ini
├── reuter.ini
├── team.ini
└── README.md
```

Keep credentials out of it where possible: private-repo access control does
not eliminate the risks of credentials copied through clones, backups, CI, or
developer machines (the service-account auth policy — passwords vs.
certificates — is a deferred decision; see
`doc/plans/2026-09-09-ema-prod-instance-at-create-manual-reuter.md`).

## .private-source

Each deploy/dev machine holds an untracked, git-ignored `.private-source` file
that points at a checkout of the private repo. It never discloses the private
repo's hosting provider or URL in the public history (it is git-ignored).

Copy the committed `.private-source.example` to `.private-source` and set one
retrieval mechanism:

```ini
PRIVATE_DATA_SOURCE=/srv/private-config            # a local checkout
# PRIVATE_DATA_GIT=git@example.com:team/app-private.git   # or a git URL
# PRIVATE_DATA_REF=main
```

When neither `PRIVATE_DATA_SOURCE` nor `PRIVATE_DATA_GIT` is set, the private
files are expected to already be present directly in `etc/` (see below).

## fetch-private-data

```bash
fetch-private-data [target-dir]   # default: $PWD
```

`fetch-private-data` reads `.private-source` and injects the private files
into `etc/`. It resolves the source in order:

1. `PRIVATE_DATA_SOURCE` — a local checkout of the private repo (no git
   needed); symlinks `machines.ini`/`reuter.ini`/`team.ini` into `etc/`.
2. `PRIVATE_DATA_GIT` + `PRIVATE_DATA_REF` — an on-demand clone/fetch into the
   git-ignored `var/private-data` (requires git; dev-only); then symlinks into
   `etc/`.
3. Neither set — the private files are expected to already be present directly
   in `etc/` (regular files, e.g. shipped by the private repo's `git archive`
   deploy). Validated warn-only; never aborts (deploy is the abort gate for a
   missing `machines.ini`).

For the private-repo modes (1 and 2), a missing `machines.ini` or
`reuter.ini` aborts (deploy cannot run without the prod roster, and the app
cannot resolve a database without `reuter.ini`); a missing `team.ini` only
warns (team DB users disabled). It is a silent no-op when `.private-source` is
absent, so the repo stays fully functional without private data (dev/sandbox
work and environments that do not need production data proceed without it).

`bin/pf-deploy.sh`, the `make dev-init` target, and `bin/dev/init-local-env.sh`
call `fetch-private-data` before they read `machines.ini`/`reuter.ini`/
`team.ini`, so the private data is present for deploy and dev-init whenever a
`.private-source` is configured.

## Production (no git)

Prod hosts have no git, so the on-demand clone path is dev-only. The private
repo is deployed to prod with `git archive`, run from a machine that has git:

```bash
git -C <private-config> archive HEAD machines.ini reuter.ini team.ini \
  | ssh root@$HOST "mkdir -p /srv/apps/<app>/etc && tar -x -C /srv/apps/<app>/etc"
```

The extracted files land directly in `etc/` (regular files, no symlinks) and
`fetch-private-data`'s fallback (mode 3) recognizes them. Alternatively,
extract into a stable directory and point `PRIVATE_DATA_SOURCE` at it.

## Security boundary

The `.private-source` pointer provides information separation only. The real
security boundary is access control on the private repository (and on the
production systems). Repository privacy must be enforced by authentication and
authorization, not by hiding the private repo's identity.
