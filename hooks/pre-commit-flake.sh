#!/usr/bin/env sh
set -euo pipefail

# Only act when flake.nix is staged.
git diff --cached --name-only | grep -qx 'flake.nix' || exit 0

nix flake lock

if git diff --name-only -- flake.lock | grep -qx 'flake.lock'; then
    cat >&2 <<'EOF'
flake.lock was refreshed (existing inputs kept pinned).
Review the diff, then stage it and commit again:
      git add flake.lock
EOF
    exit 1
fi

echo "flake.lock already in sync." >&2
