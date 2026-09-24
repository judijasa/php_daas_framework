#!/usr/bin/env bash

# pf-deploy.sh — project-agnostic deployment CLI (php_daas_framework).
#
# Ships a consumer repo to a remote production server with a near-atomic
# swap, then copies the nix closure, installs composer dependencies, runs
# idempotent provisioning, regenerates the per-host runtime env (.env +
# /etc/<instance>/reuter.ini), and installs cron on every host, filtered by
# that host's tag list (cron `scope`).
#
# Configuration is loaded from the consumer repo root: `.env` (machine
# settings, same contract as `phprun`) for REPO_PATH, the git-ignored
# etc/deploy.conf (the consumer's real deploy config, sourced as a plain
# file) for the project deploy parameters, and the git-ignored
# etc/machines.ini machine registry. Run from the repo root, inside
# `nix develop`.
#
# Private config: the framework ships the consumer-declared private files
# (DEPLOY_PRIVATE_FILES) into the freshly swapped etc/ and replays the deploy
# machine's deploy.conf environment to every remote step, so a prod host needs
# no deploy.conf of its own. A consumer that commits a real etc/deploy.conf
# still works — host-side scripts source the file only when present.
#
# Config surfaces in the consumer repo root:
#   etc/deploy.conf  (git-ignored, consumer-owned; required on the deploy
#   machine) - project deployment target, shared by every prod host:
#     PROD_USER              unprivileged app user on the remote host
#                            (must exist with SSH access before first deploy)
#     DEPLOY_TARGET_DIR      remote repo location (e.g. /srv/apps/<app>)
#     DEPLOY_LOG_DIR         remote log dir (deploy_version.log lives here)
#     DEPLOY_REUTER_INI     remote path of the consumer's manual reuter.ini
#                            (the [<dbname>] connectivity recorded from
#                            `ema create`); gen-env projects it as REUTER_INI
#     DEPLOY_NIX_RESULT_DIR  remote nix result parent (e.g. /usr/local/<app>)
#     DEPLOY_NIX_GCROOT      remote nix gcroot (e.g. /nix/var/nix/gcroots/<app>)
#     DEPLOY_PRIVATE_FILES   optional: space-separated etc/-relative private
#                            file names the framework ships from the deploy
#                            machine's etc/ into the freshly swapped etc/ on
#                            the host. Skipped if unset.
#     DEPLOY_INIT_CMD        optional: consumer-specific provisioning command
#                            run after the generic provision; skipped if unset.
#   etc/machines.ini  (git-ignored; template committed) - prod machine registry:
#     [prod] ZeroTier-IP -> comma-separated `tag[:name]` tokens (a `db:<name>`
#            token names a database and enforces the one-to-one server mapping
#            — the instance itself is provisioned by `ema create`, not by
#            deploy, and db-check verifies it via the host's own `mariadb@*`
#            units, not this roster; every token doubles as a cron scope and
#            `host`-scoped jobs run on every host; empty entries are code-only
#            servers; each named token maps to exactly one server)
#
# Usage:
#   pf-deploy.sh                # deploy to every [prod] host in etc/machines.ini
#   pf-deploy.sh <target_host>  # deploy to a single prod host (must be in [prod])
#   .env  (git-ignored, machine-specific) - same contract as `phprun`:
#     REPO_PATH              consumer repo root (set by the consumer's dev-init)
#
# Architecture notes:
# - Nix packages are built locally and copied (not built on the server) to
#   keep server-side build resources minimal. Local + remote must both be
#   x86_64: one composer dependency (the Casper crawler) ships binaries for
#   x86_64 only, so the script stays single-architecture for readability.

set -euo pipefail

# Load machine-specific settings from a .env in the current working directory
# (the consumer repo root), same contract as bin/phprun. Values in .env
# override anything already in the environment.
if [[ -f "$PWD/.env" ]]; then
  set -a
  . "$PWD/.env"
  set +a
fi

# Load the deploy config from a git-ignored etc/deploy.conf. The real file is
# consumer-owned and sourced as a plain file — the framework ships only
# etc/deploy.conf.template and never fetches, ships or symlinks it. Unlike
# .env (generated per environment), deploy.conf describes the deployment
# target. It is required.
if [[ ! -f "$PWD/etc/deploy.conf" ]]; then
  echo "pf-deploy: $PWD/etc/deploy.conf not found" >&2
  echo "  Copy etc/deploy.conf.template to etc/deploy.conf and fill in the values — see doc/system/consumer-config.md." >&2
  exit 1
fi
_ENV_BEFORE="$(compgen -e | sort)"
set -a
. "$PWD/etc/deploy.conf"
set +a
_ENV_AFTER="$(compgen -e | sort)"

# Serialize the variables etc/deploy.conf adds, as sourceable
# `declare -x NAME="value"` lines. The deployed repo carries no deploy.conf,
# so the deploy machine's deploy.conf environment is replayed to every
# post-swap remote step (see deploy_to_host).
DEPLOY_CONF_ENV=""
while IFS= read -r _v; do
  [ -n "$_v" ] || continue
  DEPLOY_CONF_ENV+="$(declare -p "$_v")"$'\n'
done < <(comm -13 <(printf '%s\n' "$_ENV_BEFORE") <(printf '%s\n' "$_ENV_AFTER"))
unset _v

# Load the machine registry (git-ignored; template committed, consumer-owned).
# [prod] lists every prod deploy target by ZeroTier IP; the host whose
# `tag[:name]` list carries a `db:` token is the database host. Every token is
# also a cron scope (`host`-scoped jobs run on every host), passed as
# HOST_TAGS to the server steps for scope filtering.
if [[ ! -f "$PWD/etc/machines.ini" ]]; then
  echo "pf-deploy: $PWD/etc/machines.ini not found" >&2
  echo "  Copy etc/machines.ini.template to etc/machines.ini and fill in the [prod] roster." >&2
  exit 1
fi

# Locate the shared roster parser next to this script (resolves vendor/bin
# symlinks, same pattern as bin/phprun).
ROSTER_BIN="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)/pf-roster"

# Print each [prod] entry as "zerotier-ip=<comma-separated tag list>" (the
# host's `tag[:name]` tokens). `main` parses this to build the deploy roster.
# The shared pf-roster CLI owns the machines.ini parse, also used by the
# consumer deploy wrapper.
read_prod_roster() {
  "$ROSTER_BIN" --list
}

require_config() {
  local missing="" _v
  for _v in REPO_PATH PROD_USER DEPLOY_TARGET_DIR DEPLOY_LOG_DIR DEPLOY_NIX_RESULT_DIR DEPLOY_NIX_GCROOT; do
    if [ -z "${!_v:-}" ]; then
      missing="$missing $_v"
    fi
  done
  if [ -n "$missing" ]; then
    echo "pf-deploy: missing required config (REPO_PATH from .env; PROD_USER/DEPLOY_* from etc/deploy.conf):$missing" >&2
    exit 1
  fi
}

flight_checks() {
  local REMOTE_HOST="$1"
  if [[ ! -n $IN_NIX_SHELL ]]; then
      echo "ERROR: This script must be run inside 'nix develop'"
      exit 1
  fi

  if [[ "$PWD" != "$REPO_PATH" ]]
  then
    echo "This command must be executed from the repository's root directory."
    exit 1
  fi

  if [ "$(git branch --show-current)" != "main" ]; then
    echo "ERROR: not on main branch"
    exit 1
  fi

  # Fetch the latest remote state without merging
  git fetch origin main 2>/dev/null
  local LOCAL_REPO_STATE=$(git rev-parse main)
  local REMOTE_REPO_STATE=$(git rev-parse origin/main)
  if [ "$LOCAL_REPO_STATE" != "$REMOTE_REPO_STATE" ]; then
    echo "ERROR: local main is not up to date with origin/main"
    echo "Local:  $LOCAL_REPO_STATE"
    echo "Remote: $REMOTE_REPO_STATE"
    exit 1
  fi

  if ! git diff --quiet || ! git diff --cached --quiet; then
    echo "ERROR: working tree is not clean"
    exit 1
  fi

  if ping -c 1 -W 2 "${REMOTE_HOST}" &> /dev/null; then
    echo "Host ${REMOTE_HOST} is online."
  else
    echo "Host ${REMOTE_HOST} is unreachable."
    exit 1
  fi
}

deploy_repo_remotely() {
  local REMOTE_HOST="$1"
  local PROD_USER="$2"
  local REMOTE_TARGET_DIR="$3"
  local REV="$4"

  echo "Deploying commit: $REV" >&2

  # Deploy (atomic on remote)
  git archive "$REV" | ssh "root@$REMOTE_HOST" "
      set -e

      if ! id \"$PROD_USER\" &>/dev/null; then
          echo \"User $PROD_USER doesn't exist. Create and setup ssh access to it.\" >&2
          exit 1
      fi

      # Define directories based on structural paths
      BASE_DIR=\$(dirname '$REMOTE_TARGET_DIR')
      FINAL_DIR='$REMOTE_TARGET_DIR'
      BACKUP_DIR=\"\${FINAL_DIR}_backup\"
      LOG_DIR='$DEPLOY_LOG_DIR'

      # Unpack inside the same parent base directory to ensure fast rename across the same mount point
      mkdir -p \"\$BASE_DIR\"
      TMP_DIR=\$(mktemp -d -p \"\$BASE_DIR\")
      echo 'Unpacking to temp...' >&2
      tar -x -C \"\$TMP_DIR\"

      # Ensure permissions are set before pushing live
      mkdir -p \"\$LOG_DIR\"
      chown -R $PROD_USER:$PROD_USER \"\$TMP_DIR\"
      chown $PROD_USER:$PROD_USER \"\$LOG_DIR\"

      # Clear out any previous backup directory
      rm -rf \"\$BACKUP_DIR\"

      # Near-Atomic Swap: Move current to backup, and instantly place the new one
      if [ -d \"\$FINAL_DIR\" ]; then
          echo 'Moving current codebase to backup...' >&2
          mv \"\$FINAL_DIR\" \"\$BACKUP_DIR\"
      fi

      echo 'Activating new repository codebase...' >&2
      mv \"\$TMP_DIR\" \"\$FINAL_DIR\"

      # Handle logging and capture old version output for stdout
      LOG_FILE=\"\$LOG_DIR/deploy_version.log\"
      touch \"\$LOG_FILE\"
      chown $PROD_USER:$PROD_USER \"\$LOG_FILE\"

      # Append current deployment info
      echo \"\$(date +'%Y-%m-%d %H:%M:%S %Z'): $REV\" >> \"\$LOG_FILE\"
      echo \"Deploy complete: $REV\" > \"\$FINAL_DIR/.deploy_version\"
      chown $PROD_USER:$PROD_USER \"\$FINAL_DIR/.deploy_version\"

      # Piggyback: Check if nix daemon is running (multi-user install)
      if systemctl is-active --quiet nix-daemon; then
        NIX_INSTALLED='true'
      else
        NIX_INSTALLED='false'
      fi

      # Output previous hash, NIX_INSTALLED, and arch to stdout (separated by spaces)
      if [ -s \"\$LOG_FILE\" ]; then
          echo \"\$(tail -n 1 \"\$LOG_FILE\" | awk '{print \$NF}') \$NIX_INSTALLED \$(uname -m)\"
      else
          echo \"None \$NIX_INSTALLED \$(uname -m)\"
      fi
  "
}

install_nix_remotely() {
  local REMOTE_HOST="$1"
  local PROD_USER="$2"
  echo "Installing Nix (multi-user) on $REMOTE_HOST..."
  if ! ssh "root@$REMOTE_HOST" "
    set -e
    curl -L https://nixos.org/nix/install | sh -s -- --daemon --yes
    mkdir -p /etc/nix
    echo 'trusted-users = root $PROD_USER' >> /etc/nix/nix.conf
    systemctl restart nix-daemon
  "; then
      echo "Nix installation failed."
      return 1
  fi
  echo "Nix installed successfully."
}

deploy_nix_packages() {
  # - Shipping binaries instead of bulding from server is convenient
  #   if server is hardware limited, as it needs build resources:
  #   compilers, -dev packages, 20GB of disk, etc.
  # - Ship Nix store folder structure (i.e. the symlinks to nix/store)
  # - Keep /usr/local/<app>/result/ root owned. This because
  #   PROD_USER only needs to read/exec Nix binaries and if
  #   PROD_USER writes here, it could inject malicious executables.
  # - Keep the store gcroot at /nix/var/nix/gcroots/<app> (root-owned).
  #   With one user per project, a project-named path under /home is
  #   redundant, so the root lives in the system gcroot dir instead.
  local REMOTE_HOST="$1"
  local PROD_USER="$2"
  local REMOTE_TARGET_DIR="$3"

  local NIX_GCROOT_DIR NIX_GCROOT_NAME
  NIX_GCROOT_DIR="$(dirname "$DEPLOY_NIX_GCROOT")"
  NIX_GCROOT_NAME="$(basename "$DEPLOY_NIX_GCROOT")"

  ssh "root@$REMOTE_HOST" "
    set -e
    mkdir -p '$DEPLOY_NIX_RESULT_DIR' '$NIX_GCROOT_DIR'
    ln -sf /nix/var/nix/profiles/default/bin/nix-store /usr/local/bin/nix-store
  "

  if ! nix eval ".#packages.x86_64-linux.default" &>/dev/null; then
    echo "WARNING: No nix package for x86_64-linux in flake. Skipping nix package deployment."
    return 0
  fi

  local REMOTE_STORE_PATH
  echo "Building packages locally..."
  nix build
  echo "Copying nix closure to remote..."
  nix copy --to "ssh://$PROD_USER@$REMOTE_HOST" ./result || return 1
  REMOTE_STORE_PATH=$(readlink -f ./result)
  rm -f result

  echo "Registering nix store root on remote..."
  ssh "root@$REMOTE_HOST" "
    /nix/var/nix/profiles/default/bin/nix-store --add-root $DEPLOY_NIX_GCROOT --realise $REMOTE_STORE_PATH
    ln -sfn '$REMOTE_STORE_PATH' '$DEPLOY_NIX_RESULT_DIR/result'
    # Legacy cleanup: the gcroot used to live in the prod user's home.
    rm -f '/home/$PROD_USER/.nix-gcroots/$NIX_GCROOT_NAME'
    rmdir '/home/$PROD_USER/.nix-gcroots' 2>/dev/null || true
  "
}

deploy_composer_dependencies() {
  local REMOTE_HOST="$1"
  local PROD_USER="$2"
  local REMOTE_TARGET_DIR="$3"

  # Run `composer install` on every deploy: `git archive` wipes vendor/ on
  # each deploy, so vendor/bin (the Composer-delivered framework CLIs, dev
  # scripts, and pf-provision.sh) would otherwise be empty on the remote. The
  # install is idempotent (composer.lock pins the exact dependency set), so
  # re-running it when nothing changed is cheap.
  echo "Running composer install on remote host..."
      ssh "$PROD_USER@$REMOTE_HOST" "
          export PATH='$DEPLOY_NIX_RESULT_DIR/result/bin':\$PATH
          cd '$REMOTE_TARGET_DIR' && composer install
      "
}

ARGS=()

while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --) shift; ARGS+=("$@"); break ;; # Stop parsing flags
    -*) echo "Unknown option: $1"; exit 1 ;;
    *) ARGS+=("$1") ;;
  esac
  shift
done

main() {
  require_config

  # Build the prod roster from etc/machines.ini (via the shared pf-roster
  # CLI): hosts are ZeroTier IPs; the value is that host's `tag[:name]`
  # token list. A host carrying a `db:` token is the database host.
  local -a hosts=() taglists=()
  local host taglist i
  while IFS='=' read -r host taglist; do
    [ -n "$host" ] || continue
    hosts+=("$host")
    taglists+=("$taglist")
  done < <(read_prod_roster)

  if [ "${#hosts[@]}" -eq 0 ]; then
    echo "pf-deploy: [prod] roster in etc/machines.ini is empty." >&2
    exit 1
  fi

  # Enforce one-to-one named-tag -> server: a named token (`tag:name`) may
  # not be listed on two servers (bare flags carry no name, hence no
  # constraint). The shared pf-roster CLI owns this validation.
  if ! "$ROSTER_BIN" --validate; then
    exit 1
  fi

  # Optional explicit host: deploy to that one only (must be in [prod]).
  if [ "${#ARGS[@]}" -gt 0 ]; then
    if [ "${#ARGS[@]}" -gt 1 ]; then
      echo "pf-deploy: at most one target host may be given (got: ${ARGS[*]})" >&2
      exit 1
    fi
    local wanted="${ARGS[0]}"
    for i in "${!hosts[@]}"; do
      if [ "${hosts[$i]}" = "$wanted" ]; then
        deploy_to_host "${hosts[$i]}" "${taglists[$i]}"
        return 0
      fi
    done
    echo "pf-deploy: host '$wanted' is not in the [prod] roster of etc/machines.ini." >&2
    exit 1
  fi

  # Default: deploy to every prod host.
  for i in "${!hosts[@]}"; do
    deploy_to_host "${hosts[$i]}" "${taglists[$i]}"
  done
}

# Per-host deploy pipeline. A database host (its tag list carries a `db:`
# token) names a database — the instance itself is provisioned by `ema
# create`, not here (db-check verifies it via the host's own `mariadb@*`
# units). The host's own tag list is passed as HOST_TAGS to the server steps
# for scope-filtered cron install, which runs on every host.
deploy_to_host() {
  local HOST="$1"
  local TAGLIST="$2"

  # Fail fast (before shipping): a repo that declares #[CronJob] jobs must set
  # CRON_FILE in etc/deploy.conf. The same file is deployed to every host, so
  # this also mirrors the remote guard in the server steps below.
  if grep -Rqs '#\[CronJob' src/ && [ -z "${CRON_FILE:-}" ]; then
    echo "pf-deploy: this repo declares #[CronJob] attributes but etc/deploy.conf sets no CRON_FILE." >&2
    echo "  Add CRON_FILE (and optionally CRON_USER) to etc/deploy.conf — see deploy.conf.template." >&2
    exit 1
  fi

  flight_checks "$HOST"
  local REMOTE_HOST="$HOST"
  local PROD_USER="${PROD_USER:?}"
  local REMOTE_TARGET_DIR="$DEPLOY_TARGET_DIR"
  local REV=$(git rev-parse HEAD)

  if ! OUTPUT=$(deploy_repo_remotely $REMOTE_HOST $PROD_USER $REMOTE_TARGET_DIR $REV); then
    echo "Failed to deploy repository."
    exit 1
  fi
  read -r PREVIOUS_REV NIX_EXISTS REMOTE_ARCH <<< "$OUTPUT"
  if [ "$REMOTE_ARCH" != "x86_64" ] || [ "$(uname -m)" != "x86_64" ]; then
    echo "ERROR: Both local ($(uname -m)) and remote ($REMOTE_ARCH) must be x86_64."
    exit 1
  fi
  [ "$NIX_EXISTS" != "true" ] && install_nix_remotely "$REMOTE_HOST" "$PROD_USER" || true
  deploy_nix_packages "$REMOTE_HOST" "$PROD_USER" "$REMOTE_TARGET_DIR"  # keep it before deploying composer
  deploy_composer_dependencies "$REMOTE_HOST" "$PROD_USER" "$REMOTE_TARGET_DIR"
  # Private config, framework-owned transport (B): ship the files the consumer
  # declares in DEPLOY_PRIVATE_FILES into the freshly swapped etc/ in one step
  # — no stable per-app dir, no consumer hook. Values from etc/deploy.conf are
  # NOT shipped as a file; they are replayed as environment to every remote
  # step below (A).
  if [ -n "${DEPLOY_PRIVATE_FILES:-}" ]; then
    echo "Shipping private files ($DEPLOY_PRIVATE_FILES) to $REMOTE_HOST..." >&2
    tar -C etc -cf - $DEPLOY_PRIVATE_FILES | ssh "root@$REMOTE_HOST" "
      set -e
      cd '$REMOTE_TARGET_DIR'
      mkdir -p etc
      tar -x -C etc --no-same-owner
      for _f in $DEPLOY_PRIVATE_FILES; do chown $PROD_USER:$PROD_USER \"etc/\$_f\"; done
    "
  fi

  # Deploy config replay (A): every post-swap remote step gets the deploy
  # machine's deploy.conf environment, so the host needs no deploy.conf of its
  # own. A consumer that commits a real etc/deploy.conf still overrides it —
  # the host-side scripts source the file only when present.
  echo "Checking the required deploy config on remote..." >&2
  ssh "root@$REMOTE_HOST" "cd '$REMOTE_TARGET_DIR' && bash -s" <<EOF
set -euo pipefail
$DEPLOY_CONF_ENV
# The required values must be in scope now — from the replayed environment or a
# committed deploy.conf. No hard file requirement.
for _v in DEPLOY_TARGET_DIR DEPLOY_LOG_DIR DEPLOY_REUTER_INI DEPLOY_NIX_RESULT_DIR DEPLOY_NIX_GCROOT; do
    if [ -z "\${!_v:-}" ]; then
        echo "pf-deploy: missing required config on host: \$_v" >&2
        exit 1
    fi
done
EOF
  # Generic provisioning (framework mechanism, shipped in the deployed repo):
  # assert PROD_USER, create permanent dirs — parameterized by the replayed
  # deploy.conf environment (or a committed etc/deploy.conf). Idempotent, so it
  # runs on every deploy. (Database instances are provisioned by `ema create`
  # at database-creation time, not here.)
  echo "Running generic provisioning (vendor/bin/pf-provision.sh) on remote..." >&2
  ssh "root@$REMOTE_HOST" "cd '$REMOTE_TARGET_DIR' && bash -s" <<EOF
set -euo pipefail
$DEPLOY_CONF_ENV
vendor/bin/pf-provision.sh
EOF
  # Optional consumer-specific extras, run after the generic step.
  if [ -n "${DEPLOY_INIT_CMD:-}" ]; then
    echo "Running consumer provisioning (DEPLOY_INIT_CMD) on remote..." >&2
    ssh "root@$REMOTE_HOST" "cd '$REMOTE_TARGET_DIR' && bash -s" <<EOF
set -euo pipefail
$DEPLOY_CONF_ENV
$DEPLOY_INIT_CMD
EOF
  fi

  # Framework server steps (run on every host): gen-env regenerates .env;
  # db-check verifies DB connectivity (warn-only, never repairs); cron install
  # runs on every host, scope-filtered by this host's own tag list (HOST_TAGS).
  # The steps run from the deployed repo root with the replayed deploy.conf
  # environment; the private etc/ files were shipped above.
  echo "Running framework server steps (gen-env, db-check, cron install) on remote..." >&2
  ssh "root@$REMOTE_HOST" "cd '$REMOTE_TARGET_DIR' && HOST_TAGS='$TAGLIST' bash -s" <<EOF
set -euo pipefail
$DEPLOY_CONF_ENV
vendor/bin/pf-server-steps.sh
EOF

  # Here, you can also clear any caches or perform other post-deployment tasks
  # Perhaps better to clear caches in src/scripts/maintenance cron jobs.
}
main "${ARGS[@]}"
exit 0
