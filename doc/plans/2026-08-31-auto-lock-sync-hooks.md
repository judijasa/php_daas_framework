# Auto lock-sync hooks (composer + flake) — Plan & Progress

Date: 2026-08-31
Repos: php_daas_framework (this repo); consumers + ../ema mirror the scripts
       via their own plans.

## Decision

`hooks/pre-commit-composer.sh` today treats "keep composer.lock in sync with
composer.json" as a mutating job: it deletes the lock and vendor/, re-resolves
(a de-facto full `composer update` that bumps every dependency), and silently
re-stages the lock. Replace it with a non-mutating gate that fails when the
lock is stale and prints the single follow-up command —
`composer update --minimal-changes`, which re-locks without bumping pinned
versions and naturally adds/removes any changed dependencies.

Add a parallel flake gate: when `flake.nix` is staged, run `nix flake lock`
(no-bump by default) and fail for manual review/staging of `flake.lock`. The
flake gate may generate the lock because `nix flake lock` has no "unsafe"
mode, but — like the composer gate — it never stages it.

Scope: the composer gate applies only where a `composer.lock` is committed
(this repo + consumers, not ../ema — a library). The flake gate applies
wherever a `flake.lock` is committed (this repo, consumers, ../ema). ../ema
additionally adopts the pre-commit framework (it has none today) so it can
host the flake gate now and a linter later.

## Script shape

`hooks/pre-commit-composer.sh` (check-only):

```sh
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
```

`hooks/pre-commit-flake.sh` (safe re-lock, no auto-stage):

```sh
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
```

## Changes

### php_daas_framework (this repo)

- [x] `hooks/pre-commit-composer.sh`: drop `rm -f composer.lock`,
      `rm -rf vendor`, `composer install`, `git add composer.lock`; check-only
      via `composer validate --no-check-all --no-check-publish
      --no-check-version --check-lock --strict`, printing the
      `composer update --minimal-changes` follow-up on failure.
- [x] `.pre-commit-config.yaml`: tighten the `composer` id `files:` from `.*`
      to `^composer\.json$`.
- [x] `hooks/pre-commit-flake.sh` (new): `nix flake lock` on staged
      `flake.nix`; fail for manual `git add flake.lock` (never auto-stage).
- [x] `.pre-commit-config.yaml`: register the `flake` local id
      (`files: ^flake\.nix$`).

## Open items

- ../ema: adopt the pre-commit framework to host the flake gate — add
  `pre-commit = pkgs.pre-commit` to `flake.nix` `buildInputs`, create
  `.pre-commit-config.yaml` + `hooks/pre-commit-flake.sh`, wire
  `pre-commit install` into `make dev-init`, and add `/vendor/` +
  `composer.lock` to `.gitignore`. Tracked in ../ema's own plan.
- consumers: mirror the two scripts + config entries in each consumer repo;
  tracked in each consumer's own plan (not named here).
- Coexists with the ema pin-sync gate in
  `doc/plans/2026-08-28-lock-sync.md`; distinct hook ids (`composer`, `flake`,
  `lock-sync`), no collision.
- ema linter (phpstan or similar): out of scope here — this adoption is the
  enabler, to be landed in a later commit.
