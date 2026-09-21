# tmux-remote dev shell — Plan & Progress

Date: 2026-09-20
Repos: php_daas_framework (this repo).

## Decision

Add a framework-owned `bin/tmux-remote` client-side CLI that drops into an
interactive tmux session on a consumer host, preloaded with that consumer's
nix-built runtime environment (php/composer/mariadb/jq/tmux, plus `phprun` and
`ema`). Plain `ssh <app>-<name>` remains the untouched non-nix path — this CLI
only adds the nix-enabled convenience shell.

The app prefix is never typed. Both `gen-ssh-config` and `tmux-remote` derive
`<app>` from `basename "$PWD"` (the repo directory you are standing in), so
`gen-ssh-config` drops its `<app>` positional. To touch another app you open
that app's own shell; there is no override flag.

The remote tmux is configured via a framework-shipped file: red status bar,
prefix `C-a` (so it never clashes with a local `C-b` tmux you launch from),
`unbind C-b`, and `bind C-a send-prefix` (so `C-a C-a` still passes a literal
`C-a` through to readline).

## Mechanism & data ownership

Framework owns the mechanism (the CLI and the remote tmux config); the
consumer owns the data (`etc/deploy.conf` values: `DEPLOY_TARGET_DIR` and the
nix result dir). The CLI reads `./etc/deploy.conf` from the current directory
rather than hardcoding any consumer path.

`tmux-remote <name>` resolves the ssh alias `<app>-<name>`, then runs on the
host (reusing only the PATH formula from `pf-server-steps.sh`, not that deploy
script):

```text
cd "$DEPLOY_TARGET_DIR" && source .env \
  && export PATH="$PWD/vendor/bin:$DEPLOY_NIX_RESULT_DIR/result/bin:$PATH" \
  && tmux -f "$DEPLOY_TARGET_DIR/vendor/<pkg>/etc/tmux-remote.conf" new-session -A -s <name>
```

The tmux session name is `<name>` (the short host name) — the app context is
already carried by the local tmux session the operator launches from.

## Changes

### php_daas_framework (this repo)

- [x] `bin/tmux-remote` (new) — client-side CLI: `tmux-remote <name>`; derive
      `<app>` = `basename "$PWD"`; resolve alias `<app>-<name>`; read
      `./etc/deploy.conf` for `DEPLOY_TARGET_DIR` (and `DEPLOY_NIX_RESULT_DIR`);
      ssh and run the remote command above. Two fail-loud guards added during
      implementation: the alias must resolve to a real `HostName` (checked with
      `ssh -G`, and the error points at `gen-ssh-config`), and the remote config
      file must exist right before tmux starts.
- [x] `bin/gen-ssh-config` — drop the `<app>` positional; derive
      `<app>` = `basename "$PWD"` unconditionally.
- [x] `etc/tmux-remote.conf` (new) — remote tmux config: red status bar, prefix
      `C-a`, `unbind C-b`, `bind C-a send-prefix`. The bar is set with
      `status-style "bg=red,fg=white"`: the planned `status-bg` spelling still
      parses on modern tmux but no longer drives the bar (verified locally
      against tmux 3.7).
- [x] `composer.json` — add `bin/tmux-remote` to the `bin` array.
- [x] `doc/system/tmux-remote.md` (new) — usage, env contract, config file,
      session/prefix conventions.
- [x] `doc/system/ssh-config.md` — `<app>` is derived from the repo dir, no
      longer a positional.
- [x] `README.md` — list `bin/tmux-remote` and point at
      `doc/system/tmux-remote.md`.
- [x] `doc/plans/2026-09-20-tmux-remote.md` — this doc.

## Open items

- **remote config path** — settled during implementation: the host-side path is
  derived from the CLI's own resolved location relative to the repo root
  (`vendor/<pkg>/etc/tmux-remote.conf` for a consumer, `etc/tmux-remote.conf`
  when this repo deploys itself), so no package name is hardcoded and both
  layouts resolve. The `vendor/bin/tmux-remote` symlink is followed one level
  and no further, so a path-repository consumer (whose `vendor/<vendor>/<pkg>`
  is itself a symlink to another checkout) still resolves to the path the host
  has.
- **env sourcing** — the formula assumes the consumer's remote `.env` is
  bash-sourceable; if a consumer ships a non-sourceable env file, revisit
  (out of scope for this repo's first cut). It is sourced under `set -a`, so a
  missing `export` keyword is not a problem.
