#!/usr/bin/env bash
# Point git at the repo's tracked hooks/ directory (git-native pre-commit and
# pre-push dispatchers), replacing the pre-commit framework.
# Backend for the Makefile target _dev-init-git-hooks (make dev-init).

set -euo pipefail

hooks_dir="$(git rev-parse --show-toplevel)/hooks"
git config core.hooksPath "$hooks_dir"
echo "Git hooks path set to: $hooks_dir"
