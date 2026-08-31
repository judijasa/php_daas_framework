#!/usr/bin/env sh
set -euo pipefail

# Only act when composer.json is staged.
git diff --cached --name-only | grep -qx 'composer.json' || exit 0

if composer validate --no-check-all --no-check-publish --no-check-version \
        --check-lock --strict; then
    exit 0
fi

cat >&2 <<'EOF'
composer.lock is out of date with composer.json.

Run:  composer update --minimal-changes   # re-lock, no bumps; adds/removes as needed
Then: git add composer.lock
EOF
exit 1
