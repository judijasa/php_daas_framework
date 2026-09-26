# Dev ssh config generation

Date: 2026-09-15
Scope: the dev machine's ssh aliases for a consumer's servers. The framework
owns the mechanism (`bin/gen-ssh-config`); the consumer owns the data (its
`hosts` name→IP mapping, the repo directory name that supplies `<app>`, and the
user/key choice).

## What it writes

`gen-ssh-config` reads the consumer's `hosts` mapping — the same private file
its `/etc/hosts` merge reads (see `doc/system/consumer-config.md`) — and emits
one drop-in per app:

```text
# ~/.ssh/config.d/<app>.conf
# generated: <app>-ssh-config
# Managed by gen-ssh-config - do not edit; re-run the generator instead.

Host <app>-<name>
  HostName <ip>
  User <user>
  IdentityFile <key>
  IdentitiesOnly yes
# end: <app>-ssh-config
```

Every `hosts` entry (`ip name`) becomes one `Host <app>-<name>` block. The CLI
is client-side and dev-only: it writes `~/.ssh/config.d/<app>.conf` on the
machine it runs on, and nothing it writes is shipped to a host.

```bash
gen-ssh-config [--hosts <path>] [--user <user>] [--key <path>]
```

`<app>` is never typed: it is `basename "$PWD"`, the repo directory the CLI is
run from. The aliases it prefixes are what `tmux-remote` resolves (see
`doc/system/tmux-remote.md`), so both derive `<app>` the same way and always
agree on `<app>-<name>`; to write another app's drop-in, run the CLI from that
app's own root.

| Argument | Meaning |
|---|---|
| `--hosts <path>` | name→IP mapping to read (default `etc/hosts`). |
| `--user <user>` | `User` for every generated `Host` (default `root`). |
| `--key <path>` | `IdentityFile` for every generated `Host` (default `~/.ssh/<app>-sshkey`). |

A consumer wires it into its own dev init, after the step that puts `hosts` in
place (the consumer's own consumer-config step — see
`doc/system/consumer-config.md`):

```make
_dev-ssh-config:
	@vendor/bin/gen-ssh-config --user root --key ~/.ssh/<app>-sshkey
```

## The `hosts` contract

`hosts` is private data and the single source for both the `/etc/hosts` merge
and the generated aliases: one entry per line, `ip name`. The same mapping is
what the host-taking CLIs pair a host's short name with its ZeroTier IP through
(see `doc/system/host-resolution.md`), so the name typed at those CLIs is the
name written here.

```text
<ip> <name>
```

Comments (`#`) and blank lines are ignored. Anything else is a hard error
rather than a skipped line: an entry with one or three fields, a duplicate
name, an invalid name (whitespace or glob characters — ssh reads `Host` as a
pattern list), or a file with no entries at all. A silently dropped alias is
how a dev machine ends up believing a stale ssh config is current.

`User` and `IdentityFile` are consumer parameters. The key's public half must
be authorized for `<user>` on each host; generating and installing it is an
operator step, not this CLI's.

## Conflict-free drop-ins

Several consumers may share one `~/.ssh/config.d/*.conf` drop-in — possibly
against the same server IP. Three rules keep them from colliding:

1. **One file per app** (`<app>.conf`) — a consumer only ever rewrites its own.
2. **Every alias is prefixed `<app>-`** — alias names cannot collide across
   apps even when the underlying `HostName` (the IP) is shared.
3. **One shared `Include`** — the drop-ins are read only if `~/.ssh/config`
   carries `Include config.d/*.conf`. The CLI adds it at the top, exactly
   once, and never clobbers other content (a relative `Include` path resolves
   inside `~/.ssh`). An equivalent spelling (any case, `~` or absolute path)
   counts as already present; if the line exists but is not the first active
   entry, the CLI warns that the entries above it take precedence over the
   generated aliases.

## Idempotency

The generated region is tagged (`# generated: <app>-ssh-config` …
`# end: <app>-ssh-config`) and replaced in place on every run — the same idiom
as the consumer's `/etc/hosts` merge — so re-running is the supported way to
pick up a `hosts` change and anything outside the tags is left untouched. The
write is atomic: a temp file next to the target, then a rename. A begin tag
without its matching end tag aborts instead of truncating the file.

## Requirements

`Include` needs OpenSSH >= 7.3. The CLI warns (never fails) when the local
`ssh` is older: it writes config, it does not call `ssh`.

## Notes

- `User` and `IdentityFile` are written verbatim: a shell-expanded `~` (as in
  a Makefile flag) lands in the drop-in as an absolute path, while the default
  key is written as `~/.ssh/<app>-sshkey`. Both forms work for ssh.
- The CLI does not wrap `ssh`/`scp`/`rsync`; it only writes config. The
  nix-enabled convenience shell over the generated aliases is `tmux-remote`
  (`doc/system/tmux-remote.md`); plain `ssh <app>-<name>` stays the non-nix
  path.
- `hosts` is optional private data: a consumer whose private repo provides
  none must tolerate the failure (skip the step, or pass `--hosts`); a mapping
  with no active entries is an error, never an empty alias set.
- The address field is not validated: whatever the first field holds is
  written as `HostName` verbatim, so a placeholder such as `10.147.x.10`
  reaches the drop-in and fails at `ssh` time, not at generation time.
- Prod is untouched: `reuter.ini` keeps direct IPs, and nothing generated here
  is deployed to a host.
