#!/usr/bin/env sh

set -euo pipefail

# If composer.json is staged, recreate composer.lock (and stage it) and vendor/
if git diff --cached --name-only | grep -qx "composer.json"; then
    echo "composer.json is staged. Performing tasks..."
    echo "Removing old composer.lock and vendor/..."
    rm -f composer.lock
    rm -rf vendor
    echo "Running composer install..."
    composer install
    echo "Staging new composer.lock..."
    git add composer.lock
fi
