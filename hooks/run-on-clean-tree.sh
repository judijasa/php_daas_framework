#!/usr/bin/env bash
# run-on-clean-tree.sh — temporarily stash dirty working-tree changes, run an
# arbitrary command against a clean HEAD, then restore.
#
# Usage: hooks/run-on-clean-tree.sh <command> [args...]
#
# The .git/hooks/pre-push shim (installed and patched by `make dev-init`)
# routes the pre-commit framework's pre-push stage through this script, so
# that full-repo analyzers (see phpstan-full in .pre-commit-config.yaml)
# always see exactly HEAD, never uncommitted junk.

set -euo pipefail

NEEDS_STASH=false

# 1. Detect tracked changes (staged + unstaged)
if ! git diff --quiet || ! git diff --cached --quiet; then
    NEEDS_STASH=true
fi

# 2. Detect untracked, non-ignored files
if [ -n "$(git ls-files --others --exclude-standard)" ]; then
    NEEDS_STASH=true
fi

if [ "$NEEDS_STASH" = false ]; then
    exec "$@"
fi

echo "run-on-clean-tree: stashing dirty working tree before push gate..."

if ! git stash push --include-untracked --message "run-on-clean-tree: auto-stash before pre-push gate"; then
    echo "run-on-clean-tree: WARNING — stash failed, running against dirty tree as fallback"
    exec "$@"
fi

set +e
"$@"
EXIT_CODE=$?
set -e

echo "run-on-clean-tree: restoring stashed changes..."

if ! git stash pop --index; then
    echo "run-on-clean-tree: ERROR — stash pop failed!"
    echo "   Your changes are safe in 'git stash list'."
    echo "   Recover them with:  git stash pop"
    exit 1
fi

exit $EXIT_CODE
