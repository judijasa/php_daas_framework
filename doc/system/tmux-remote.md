# Remote tmux dev shell

Date: 2026-09-20
Scope: the operator's interactive shell on a consumer host. The framework owns
the mechanism (`bin/tmux-remote`, a client-side CLI, and `etc/tmux-remote.conf`,
the remote session's tmux config); the consumer owns the data (the
`etc/deploy.conf` values and the ssh aliases its `gen-ssh-config` wrote).

## Usage

```bash
tmux-remote <host> <session>     # from the repo root
```

`<host>` is the short host name from the consumer's private `hosts` mapping
(the same one `gen-ssh-config` reads — see `doc/system/ssh-config.md`); the
ssh alias resolved is `<app>-<host>`, where `<app>` is `basename "$PWD"` — the
repo directory you are standing in — exactly the alias `gen-ssh-config` writes,
with that alias's `User` and `IdentityFile`. `<session>` is the tmux session
name on the host (letters, digits, `.`, `_`, `-`); it is explicit, so one host
can hold several named sessions and you re-attach by that name. To reach another
app you open that app's own shell; there is no override flag.

The CLI is client-side and dev-only: it runs on the operator's machine and hands
the session to the host over `ssh -t <app>-<host>`. Plain `ssh <app>-<host>`
stays the untouched non-nix path — this CLI only adds the nix-enabled
convenience shell.

## Inside the session

- **List sessions** — `tmux ls` lists every session on the host (attached and
  detached); `C-a s` opens tmux's interactive session picker.
- **Detach (keep the session)** — `C-a d`. The session keeps running on the
  host; re-attach later with `tmux-remote <host> <session>`.
- **Delete (destroy the session)** — `C-a :` then `kill-session` + Enter (or
  `exit` every pane/window). Once the last session is gone, the host's tmux
  server stops and nothing is left running.

## What runs on the host

`DEPLOY_TARGET_DIR` and `DEPLOY_NIX_RESULT_DIR` are read from the consumer's
`etc/deploy.conf` (sourced locally, the same loading contract as
`bin/pf-deploy.sh`; the file stays on the deploy machine). The host then runs:

```text
cd "$DEPLOY_TARGET_DIR" && source .env \
  && export PATH="$PWD/vendor/bin:$DEPLOY_NIX_RESULT_DIR/result/bin:$PATH" \
  && tmux -f "<framework package>/etc/tmux-remote.conf" new-session -A -s <session>
```

- **`source .env`** — the deployed repo directory is replaced on every deploy,
  so the host's `.env` is the `gen-env` projection regenerated on that deploy.
  It is sourced with `set -a` so its keys are exported even if a consumer's
  `.env` omits the `export` keyword.
- **`PATH`** — the same formula as `bin/pf-server-steps.sh` (that script's PATH
  line only, not its deploy steps): the repo's `vendor/bin` (the consumer's own
  `phprun`/`ema`) first, then the nix result bin `$DEPLOY_NIX_RESULT_DIR/result/bin`
  (php, composer, mariadb, jq, tmux). `$PWD` and `$PATH` expand on the host,
  after the `cd`.
- **`new-session -A -s <session>`** — attach to the session if it exists, create
  it otherwise. The session name is the explicit `<session>` (not the host name
  or the app): `-A` makes re-attaching idempotent, so `tmux-remote <host>
  <session>` either attaches to or creates that named session.

## The remote config file

The session is configured by the framework's own `etc/tmux-remote.conf`, shipped
inside the framework package and read on the host with `tmux -f`. Its path is
derived from the CLI's own location relative to the repo root, so no package
name is hardcoded and the host's layout mirrors this machine's:
`vendor/<vendor>/<pkg>/etc/tmux-remote.conf` for a consumer, plain
`etc/tmux-remote.conf` when this repo deploys itself. The `vendor/bin/tmux-remote`
symlink is followed one level and no further, so a path-repository consumer —
whose `vendor/<vendor>/<pkg>` is itself a symlink to another checkout — still
resolves to the path the host has.

The config sets prefix `C-a`, so it never clashes with a local `C-b` tmux you
launch it from; `unbind C-b` removes the inherited prefix, and
`bind C-a send-prefix` keeps `C-a C-a` passing a literal `C-a` to readline. The
status bar is red — `status-style "bg=red,fg=white"`, because a shell on a
production host should not be mistaken for a local session; the legacy
`status-bg`/`status-fg` spellings still parse on modern tmux but no longer drive
the bar. Do not edit the copy on a host — the deployed repo directory is
replaced on every deploy.

The config also forces the shell to run **non-login** (`default-command 'exec
"$SHELL"'`). tmux's default is to start a login shell, and a login shell sources
`/etc/profile`; on a root shell `/etc/profile` hard-resets `PATH` to the bare
system path, discarding the `vendor/bin` and nix `result/bin` that `tmux-remote`
exported into the session. A non-login shell inherits that `PATH` untouched, so
`ema` and the rest of the consumer's `vendor/bin` stay resolvable.

## Guards

Both fail loudly instead of half-working:

- **The ssh alias must be configured.** `ssh -G <app>-<host>` must resolve to a
  real `HostName`; an alias nothing matches resolves to itself, which is how the
  CLI detects it. The error points at `gen-ssh-config`.
- **The remote config file must exist.** Checked on the host, right before tmux
  starts, so a stale deploy (the framework package not yet delivered by
  `composer install`) reports itself rather than a cryptic tmux error.

## Requirements

- `tmux` on the host, from the nix result bin — like the rest of that runtime.
- The consumer's remote `.env` must be bash-sourceable (in practice it is a
  `gen-env` projection).
- The consumer's `etc/deploy.conf` must be in place locally: `tmux-remote` runs
  from the deploy machine, like `pf-deploy.sh`.

## Notes

- `ssh -t` is forced: tmux needs a terminal, and `ssh` would otherwise allocate
  a pty only implicitly (when its stdin happens to be a tty).
- The remote session is a plain tmux server on the host's default socket; the
  local session's socket/name choices (`pf-shell-enter.sh`'s `tmux` alias) are
  unrelated to it.
- The CLI reads nothing but `etc/deploy.conf` locally: no `hosts` lookup, no
  `machines.ini` roster — the ssh alias is the host's identity, resolved by ssh.
