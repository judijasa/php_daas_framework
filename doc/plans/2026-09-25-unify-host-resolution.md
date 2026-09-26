# Unified host resolution — Plan & Progress

Date: 2026-09-25
Repos: php_daas_framework (this repo, upstream mechanism).

## Decision

A host is currently spelled two ways depending on the command: `tmux-remote` takes the short name (`simo0`), while `gen-firewall` and `pf-deploy.sh` take the ZeroTier IP. The framework will make every host-taking command accept **either** spelling and resolve both through one shared lookup.

The lookup uses the two files these commands already read — `etc/hosts` (name → IP) and `etc/machines.ini [prod]` (the prod host list) — and returns the canonical host for whichever spelling it was given.

## Changes

### php_daas_framework (this repo)

- [x] Add one shared resolver (`src/host_resolver.php`) that turns a name or an IP into the canonical host, plus a small `bin/pf-host` command so the bash CLIs can call it.
- [x] `gen-firewall` — accept the name or the IP.
- [x] `tmux-remote` — accept the name or the IP.
- [x] `pf-deploy.sh` — accept the name or the IP.
- [x] `pf-roster` — switch to the shared resolver (no behavior change).
- [x] `doc/system/*` — document the argument as "short name or IP".
- [x] tests for the resolver (name, IP, unknown, not-a-prod-host).
- [x] `doc/plans/2026-09-25-unify-host-resolution.md` — this doc.

## Open items

- Consumers get this on their next composer pin bump; a consumer whose deploy wrapper re-matches the roster key must resolve the name there too.
