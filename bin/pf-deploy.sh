#!/usr/bin/env bash

# pf-deploy.sh — project-agnostic deployment CLI (php_daas_framework).
#
# Ships a consumer repo to a remote production server with a near-atomic
# swap, then copies the nix closure, installs composer dependencies, runs
# idempotent provisioning, regenerates the per-host runtime env (.env +
# /etc/<instance>/reuter.ini), and installs cron on `worker`-tagged hosts.
#
# Configuration is loaded from the consumer repo root: `.env` (machine
# settings, same contract as `phprun`) for REPO_PATH, a committed
# etc/deploy.conf for the project-static deploy parameters, and the
# git-ignored etc/machines.ini machine registry. Run from the repo root,
# inside `nix develop`.
#
# Config surfaces in the consumer repo root:
#   etc/deploy.conf  (COMMITTED, required) - project-static deployment target,
#   shared by every prod host:
#     PROD_USER              unprivileged app user on the remote host
#                            (must exist with SSH access before first deploy)
#     DEPLOY_TARGET_DIR      remote repo location (e.g. /srv/apps/<app>)
#     DEPLOY_LOG_DIR         remote log dir (deploy_version.log lives here)
#     DEPLOY_DB_BASE        remote MariaDB instance base dir (datadir/socket/
#                            pid-file derived by convention); used only on the
#                            database host, created/started by provisioning
#     DEPLOY_NIX_RESULT_DIR  remote nix result parent (e.g. /usr/local/<app>)
#     DEPLOY_NIX_GCROOT      remote nix gcroot (e.g. /nix/var/nix/gcroots/<app>)
#     DEPLOY_INIT_CMD        optional: consumer-specific provisioning command
#                            run after the generic provision; skipped if unset.
#   etc/machines.ini  (git-ignored; template committed) - prod machine registry:
#     [prod] ZeroTier-IP -> comma-separated `tag[:name]` tokens (a host with
#            a `db:<name>` token is the database host; a host carrying the
#            bare `worker` token gets the cron manifest installed; empty
#            entries are code-only servers; each named token maps to exactly
#            one server)
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

# Load project-static deploy config from a committed etc/deploy.conf. Unlike
# .env (generated per environment, git-ignored), deploy.conf is committed and
# describes the deployment target. It is required.
if [[ ! -f "$PWD/etc/deploy.conf" ]]; then
  echo "pf-deploy: $PWD/etc/deploy.conf not found" >&2
  echo "  Copy the framework's etc/deploy.conf.template into the repo and fill in the values." >&2
  exit 1
fi
set -a
. "$PWD/etc/deploy.conf"
set +a

# Inject git-ignored private config (etc/machines.ini, etc/team.ini) from the
# private repository referenced by .private-source, when configured. A no-op
# when .private-source is absent — the repo stays functional without private
# data (see bin/fetch-private-data + doc/system/private-config.md).
FETCH_BIN="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)/fetch-private-data"
"$FETCH_BIN" "$PWD"

# Load the machine registry (git-ignored; copy from machines.ini.template).
# [prod] lists every prod deploy target by ZeroTier IP; the host whose
# `tag[:name]` list carries a `db:` token is the database host, and one that
# carries the bare `worker` token gets the cron manifest installed.
if [[ ! -f "$PWD/etc/machines.ini" ]]; then
  echo "pf-deploy: $PWD/etc/machines.ini not found" >&2
  echo "  Copy the framework's etc/machines.ini.template into the repo and fill in the [prod] roster." >&2
  exit 1
fi

# Locate the shared roster parser next to this script (resolves vendor/bin
# symlinks, same pattern as bin/phprun).
ROSTER_BIN="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)/pf-roster"

# Print each [prod] entry as "zerotier-ip=<comma-separated tag list>" (the
# host's `tag[:name]` tokens). `main` parses this to build the deploy roster.
# The shared pf-roster CLI owns the machines.ini parse, also used by
# gen-reuter and the consumer deploy wrapper.
read_prod_roster() {
  "$ROSTER_BIN" --list
}

require_config() {
  local missing="" _v
  for _v in REPO_PATH PROD_USER DEPLOY_TARGET_DIR DEPLOY_LOG_DIR DEPLOY_DB_BASE DEPLOY_NIX_RESULT_DIR DEPLOY_NIX_GCROOT; do
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
          cd \\\"$REMOTE_TARGET_DIR\\\" && composer install
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
# token) gets the MariaDB instance during provisioning; a host carrying the
# bare `worker` token gets the cron manifest installed after the server
# steps. Other hosts skip both.
deploy_to_host() {
  local HOST="$1"
  local TAGLIST="$2"
  local IS_DB_HOST=0
  local IS_WORKER_HOST=0
  local _tok
  if [ -n "$TAGLIST" ]; then
    for _tok in ${TAGLIST//,/ }; do
      if [[ "$_tok" == db:* ]]; then
        IS_DB_HOST=1
      elif [[ "$_tok" == worker ]]; then
        IS_WORKER_HOST=1
      fi
    done
  fi

  # Fail fast (before shipping): a `worker` host must declare CRON_FILE in
  # etc/deploy.conf. The same file is deployed to every host, so this also
  # mirrors the remote guard in the server steps below.
  if [ "$IS_WORKER_HOST" = "1" ] && [ -z "${CRON_FILE:-}" ]; then
    echo "pf-deploy: host $HOST carries the 'worker' tag but etc/deploy.conf sets no CRON_FILE." >&2
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
  # Generic provisioning (framework mechanism, shipped in the deployed repo):
  # assert PROD_USER, create permanent dirs, initialize the MariaDB cluster —
  # all parameterized by etc/deploy.conf. Idempotent, so it runs on every
  # deploy.
  echo "Running generic provisioning (vendor/bin/pf-provision.sh) on remote..." >&2
  local PROVISION_ENV=""
  if [ "$IS_DB_HOST" = "1" ]; then
    PROVISION_ENV="DEPLOY_PROVISION_DB=1 DEPLOY_DB_BIND=$REMOTE_HOST"
  fi
  ssh "root@$REMOTE_HOST" "cd '$REMOTE_TARGET_DIR' && $PROVISION_ENV vendor/bin/pf-provision.sh"
  # Optional consumer-specific extras, run after the generic step.
  if [ -n "${DEPLOY_INIT_CMD:-}" ]; then
    echo "Running consumer provisioning (DEPLOY_INIT_CMD) on remote..." >&2
    ssh "root@$REMOTE_HOST" "cd '$REMOTE_TARGET_DIR' && $DEPLOY_INIT_CMD"
  fi

  # Framework server steps (run on every host): the repo dir is replaced on
  # every deploy, so the git-ignored .env must be regenerated before anything
  # reads it — and, on `worker` hosts, before the cron manifest is installed.
  # gen-env + gen-reuter run on every host; the cron install is gated on the
  # bare `worker` token (detected above). The remote script runs from the
  # deployed repo root and sources the DEPLOYED etc/deploy.conf, so the
  # CRON_*/DEPLOY_* values used here are the shipped ones.
  echo "Running framework server steps (gen-env, gen-reuter, cron install) on remote..." >&2
  ssh "root@$REMOTE_HOST" "cd '$REMOTE_TARGET_DIR' && IS_WORKER_HOST=$IS_WORKER_HOST bash -s" <<'PF_DEPLOY_SERVER_STEPS'
set -euo pipefail
# CWD is the deployed repo root (the ssh command above cds first).
. ./etc/deploy.conf
export PATH="$DEPLOY_TARGET_DIR/vendor/bin:$DEPLOY_NIX_RESULT_DIR/result/bin:$PATH"
instance="${DEPLOY_DB_INSTANCE:-$(basename "$DEPLOY_TARGET_DIR")}"
mkdir -p "/etc/$instance"
echo "    Regenerating production .env..." >&2
gen-env
echo "    Refreshing /etc reuter.ini [prod] connectivity..." >&2
gen-reuter "/etc/$instance/reuter.ini"
if [ "$IS_WORKER_HOST" = "1" ]; then
    if [ -z "${CRON_FILE-}" ]; then
        echo "pf-deploy: this host carries the 'worker' tag but etc/deploy.conf sets no CRON_FILE." >&2
        exit 1
    fi
    # Cron entries need both phprun (vendor/bin) and php (nix result bin) on
    # PATH; CRON_NIX_BIN becomes the crontab `NIX_BIN=` assignment prepended
    # to every entry. Consumers may override it in etc/deploy.conf.
    export CRON_NIX_BIN="${CRON_NIX_BIN:-$DEPLOY_TARGET_DIR/vendor/bin:$DEPLOY_NIX_RESULT_DIR/result/bin}"
    echo "    Updating cron jobs from #[CronJob]/#[Agent] attributes..." >&2
    cron-manifest > "$CRON_FILE"
    chmod 644 "$CRON_FILE"
    systemctl restart cron 2>/dev/null || systemctl restart crond
    echo "    Cron jobs installed to $CRON_FILE." >&2
fi
PF_DEPLOY_SERVER_STEPS

  # Here, you can also clear any caches or perform other post-deployment tasks
  # Perhaps better to clear caches in src/scripts/maintenance cron jobs.
}
main "${ARGS[@]}"
exit 0
