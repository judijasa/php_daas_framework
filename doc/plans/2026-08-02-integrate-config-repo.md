# Public repo with private config repo — Plan & Progress

Date: 2026-08-02 (adapted to the current repo 2026-09-08)
Repos: php_daas_framework (this repo)

## Decision

Separate publicly shareable framework code from private operational data: the
public repo ships only the mechanism, the committed templates, and a
`.private-source` pointer contract; the actual operational data
(`etc/machines.ini` prod roster, `etc/team.ini` member identities) lives in a
separate, access-controlled private repository. The public repo never names or
points at that private repo — each deploy/dev machine holds an untracked,
git-ignored `.private-source` file that locates it locally.

Adaptation vs. the original 2026-08-02 sketch: the repo uses `.ini`
(`etc/*.ini`, not `.yml`), and the private data is precisely the two
git-ignored operational files. `etc/deploy.conf` stays committed — it is
project-static (paths, the app-user name, port numbers — no secrets, identical
on every prod host), so it is public interface, not private data. Credentials
(`<ACCOUNT>_PASSWORD` keys) never live in either repo: they are written by the
consumer's service-user provisioning into the git-ignored, generated
`etc/reuter.ini`.

## Config model

| File | Committed | Source |
|---|---|---|
| `etc/machines.ini` | no (template yes) | private repo, injected by `fetch-private-data` |
| `etc/team.ini` | no (template yes) | private repo, injected by `fetch-private-data` |
| `etc/deploy.conf` | yes | public (project-static, no secrets) |
| `etc/reuter.ini` | no (generated) | `gen-reuter`; credentials from consumer provisioning |
| `.private-source` | no (`.private-source.example` yes) | machine-specific pointer |
| `.env` | no (generated) | `init-local-env.sh` (dev) / `gen-env` (prod) |

## Mechanism & data ownership

- **public repo** owns the mechanism + committed templates
  (`etc/machines.ini.template`, `etc/team.ini.template`,
  `.private-source.example`, `bin/fetch-private-data`).
- **private repo** is a small access-controlled git repo whose tracked files
  mirror the consumer's `etc/` operational data: `machines.ini` and
  `team.ini`.
- **`bin/fetch-private-data [target-dir]`** reads `.private-source`, resolves
  the private repo (a local `PRIVATE_DATA_SOURCE` path, or an on-demand
  `PRIVATE_DATA_GIT` clone/fetch into `var/private-data`), validates the
  expected structure (a missing `machines.ini` aborts; a missing `team.ini`
  warns), then symlinks each private file into `etc/` — leaving any local file
  untouched. It is a no-op when `.private-source` is absent, so the repo stays
  fully functional without private data.
- `bin/pf-deploy.sh` and `bin/dev/init-local-env.sh` call
  `fetch-private-data` before reading `machines.ini`/`team.ini`, so the
  private data is present for deploy and dev-init whenever a `.private-source`
  is configured.

## Changes

### php_daas_framework (this repo)

- [x] `.private-source.example` (new): the pointer contract (local path or
      git URL); the real `.private-source` is untracked and machine-specific.
- [x] `.gitignore`: ignore `.private-source`.
- [x] `bin/fetch-private-data` (new): validate + inject CLI above.
- [x] `bin/pf-deploy.sh`: call `fetch-private-data` before the
      `etc/machines.ini` existence check.
- [x] `bin/dev/init-local-env.sh`: call `fetch-private-data` before `DBUSER`
      resolution and `gen-reuter`.
- [x] `composer.json`: ship `bin/fetch-private-data` in the `bin` array.
- [x] `etc/machines.ini.template`, `etc/team.ini.template`: point at the
      private-repo injection path.
- [x] `doc/system/private-config.md` (new): the workflow and security
      boundary.
- [x] `README.md`: point at `doc/system/private-config.md`.

## Open items

- Remote-side injection is out of scope: `fetch-private-data` materializes the
  private files on the deploy/dev machine only; the consumer's deploy wrapper
  remains responsible for making `machines.ini`/`team.ini` available on the
  prod hosts (e.g. copying them alongside the deploy, or running `gen-reuter`
  locally). `git archive` never ships them — they are git-ignored.
- `etc/deploy.conf` still carries `DEPLOY_DB_BIND` (the DB host's ZeroTier IP)
  when set — the one remaining operational value in the committed config.
  Leaving it committed for now (non-secret, project-static); move it into the
  private repo only if the deploy config grows further operational values.
