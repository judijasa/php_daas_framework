# SSH config generation — Plan & Progress

Date: 2026-09-15
Repos: php_daas_framework (this repo).

## Decision

Move the dev-machine ssh config into the framework as a generic
`bin/gen-ssh-config` CLI: read a consumer's `hosts` name→IP mapping and write
`~/.ssh/config.d/<app>.conf`, so a consumer stops hand-editing its ssh aliases
as its node count grows. The CLI is client-side and dev-only — nothing it
writes is shipped to a host.

Every generated `Host` is prefixed `<app>-` for hard isolation: several
consumers sharing the same `~/.ssh/config.d/*.conf` drop-in — even against the
same server IP — cannot collide on alias names. `User` and `IdentityFile` are
consumer parameters (defaults `root` and `~/.ssh/<app>-sshkey`); a consumer
with a different access model overrides them.

## Mechanism & data ownership

The framework owns the mechanism; the consumer owns the data (its `hosts`
file, the `<app>` name, and the user/key choice).

For each `hosts` entry (`ip hostname`), the CLI emits:

```
Host <app>-<name>
  HostName <ip>
  User <user>
  IdentityFile ~/.ssh/<app>-sshkey
  IdentitiesOnly yes
```

into `~/.ssh/config.d/<app>.conf`, as an idempotent tagged block (atomic
write, same idiom as the consumer's `/etc/hosts` merge). It ensures
`~/.ssh/config.d/` exists and that `~/.ssh/config` carries the canonical
`Include config.d/*.conf` line (idempotent add, never clobbering other
content). It does not wrap `ssh`/`scp`/`rsync` — it only writes config.

## Changes

### php_daas_framework (this repo)

- [x] `bin/gen-ssh-config` (new) — read a consumer's `hosts` (name→IP), emit
      `~/.ssh/config.d/<app>.conf` (tagged block, atomic), ensure the
      `Include config.d/*.conf` line. Flags: `<app>` positional, `--hosts`
      (default `etc/hosts`), `--user` (default `root`), `--key` (default
      `~/.ssh/<app>-sshkey`).
- [x] `composer.json` — add `bin/gen-ssh-config` to the `bin` array.
- [x] `doc/system/ssh-config.md` (new) — CLI usage, data contract, the
      conflict-free drop-in rules (per-app file + `<app>-` prefix + one shared
      idempotent Include).
- [x] `README.md` — `Distribution` and "Dev-init machinery for consumers":
      list `bin/gen-ssh-config` and point at `doc/system/ssh-config.md`.
- [x] `doc/system/private-config.md` — `hosts` also feeds the generated dev
      ssh aliases, not just the consumer's `/etc/hosts` merge.
- [x] `doc/plans/2026-09-15-ssh-config.md` — this doc.

## Open items

- **address validation** — **no** for now: the first field is written as
  `HostName` verbatim, so a placeholder address (`10.147.x.10`) is not
  rejected at generation time; revisit if consumers keep recording placeholders
  in `hosts`.
- **key provisioning** — **no** for now: the CLI only names the key and user
  (`~/.ssh/<app>-sshkey` and `root` by default); generating the key and
  authorizing its public half for that user on each host stays an operator
  step.
- **`scp`/`rsync`** — **no** for now: they read the same `~/.ssh/config`, but
  the CLI does not wrap or rewrite commands; a consumer wanting short names
  under them is out of scope.
