#!/usr/bin/env sh

set -euo pipefail

# Assert the nix (flake.lock) and Composer (composer.lock) resolvers agree on
# the pinned commit for the ema package, whenever either lockfile is staged.
# Regenerating the counterpart lock alone does not guarantee agreement (a
# `dev-main` Composer constraint resolves to current main HEAD, independent of
# the flake rev), so rev equality is the authoritative gate.
#
# The row is dormant until this repo `require`s ema via Composer; until then
# ema is absent from composer.lock and the hook skips it.

# Bail unless one of the lockfiles is staged.
staged=$(git diff --cached --name-only)
if ! printf '%s\n' "$staged" | grep -qx 'flake.lock' \
    && ! printf '%s\n' "$staged" | grep -qx 'composer.lock'; then
    exit 0
fi

flake=$(jq -r '.nodes.ema.locked.rev // empty' flake.lock)
ref=$(jq -r \
    '.packages[]? | select(.name == "judijasa/ema") | .source.reference // empty' \
    composer.lock)

# Dormant row: ema not yet in composer.lock — skip silently.
if [ -z "$ref" ]; then
    exit 0
fi

if [ "$flake" != "$ref" ]; then
    echo "lock-sync: mismatch for judijasa/ema"
    echo "  flake.lock (ema):          $flake"
    echo "  composer.lock (judijasa/ema): $ref"
    echo "  Fix: pin Composer to the flake rev and regenerate:"
    echo "    composer require \"judijasa/ema:dev-main#$flake\""
    exit 1
fi
