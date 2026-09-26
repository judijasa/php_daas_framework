# Host resolution

Date: 2026-09-26
Scope: how a host-taking CLI turns either spelling of a host — the short name an
operator types, or the ZeroTier IP that is the host's identity — into the
canonical host. The framework owns the mechanism (`src/host_resolver.php` and
its `bin/pf-host` CLI); the consumer owns the data (its private `etc/hosts`
mapping and the `etc/machines.ini` `[prod]` roster).

## Two spellings, one host

Every CLI that takes a host accepts either spelling:

| CLI | Argument | Half it uses |
|---|---|---|
| `pf-deploy.sh <target_host>` | short name or ZeroTier IP | the ZeroTier IP (the `[prod]` roster key, the ssh target) |
| `gen-firewall [host\|all]` | short name or ZeroTier IP | the ZeroTier IP (the `[prod]` roster key) |
| `tmux-remote <host> <session>` | short name or ZeroTier IP | the short name (the `<app>-<name>` ssh alias gen-ssh-config wrote) |

A host's **canonical form** is the pair of its short name and its ZeroTier IP.
The IP is the identity everything else is keyed by — the `[prod]` roster key,
the `ssh root@<host>` target, the `pf-deploy.sh` target — and the name is the
operator-facing spelling the `/etc/hosts` merge and the generated dev ssh
aliases are built from. `pf-roster` takes no host argument; it shares the same
roster parse.

## The lookup

`resolve_host()` (in `src/host_resolver.php`) reads the two files these CLIs
already use and answers with the pair:

| File | Role | Required |
|---|---|---|
| `etc/hosts` | `ip name` lines — the same private mapping `gen-ssh-config` turns into dev ssh aliases; pairs the two spellings | optional: without it an IP still resolves, only its name half is unknown |
| `etc/machines.ini` `[prod]` | the prod host list, keyed by ZeroTier IP | yes: a host that is not in it is not a deploy target |

Both are consumer-owned private data (see `doc/system/consumer-config.md`) and
both are read from the working directory, so the CLIs run from the repo root.
The lookup fails loudly rather than guessing: a name with no `etc/hosts` entry
has nothing to pair it with, and a host that resolves but is not in `[prod]` is
a known machine that is not a deploy target — a mistake, not a silent no-op.

```bash
pf-host <name|ip>         # print the host's ZeroTier IP
pf-host --name <name|ip>  # print the host's short name
```

`bin/pf-host` is that lookup as a CLI, for the bash CLIs (`pf-deploy.sh`,
`tmux-remote`), which cannot call PHP functions directly; `--name` is what
`tmux-remote` needs, because the alias is keyed by the name. The PHP CLIs
(`gen-firewall`, `pf-roster`) include the module itself.

## Notes

- **The mapping is a pairing, not a second roster.** `etc/hosts` says which name
  and which IP are the same host; it never makes a host a deploy target, and
  `[prod]` membership is always enforced.
- **The roster stays IP-keyed.** `etc/machines.ini` `[prod]` keys are ZeroTier
  IPs (see `etc/machines.ini.template`); a name is a spelling of the same host,
  resolved before the roster is consulted.
- **One reading of the roster.** `prod_roster()` and the `tag[:name]` token
  splitter live in the resolver, so `pf-roster`, `gen-firewall` and
  `pf-deploy.sh` share one parse.
- **Tests.** `php tests/host_resolver.php` (or `make test`) builds both files in
  a throwaway directory and asserts the answers: a name, an IP, an unknown
  spelling, and a host outside `[prod]`.
