# gen-firewall — Plan & Progress

Date: 2026-09-18
Repos: php_daas_framework (this repo, mechanism). Consumer-side data is
       tracked in each consumer's own plan doc.

## Decision

A single standalone reconcile CLI, framework-owned, consumes a consumer
host-hardening declaration and applies it as root:

- `gen-firewall` — reset + reapply the ufw rule set. Compute the full desired
  set (baseline ∪ tag rules) *before* touching the host, then
  `ufw --force reset`, `default deny incoming` / `default allow outgoing`,
  apply the allow rules **SSH first**, and `ufw --force enable` last. Tags only
  add allows; the baseline owns the defaults and any denies, so the desired set
  is the order-independent set union of a host's tags.

It defaults to `--dry-run`. The framework owns only the *mechanism* (how the
rules are computed and applied, and the declaration schema it reads); the
tag→rule mapping, ZeroTier range and cloud flag are consumer data. sshd
hardening is out of scope here: it is a consumer-side manual pre-deployment
step (three static directives), not a framework CLI.

## Changes

### php_daas_framework (this repo)

- [x] `bin/gen-firewall` — new CLI: declaration + roster → full rule set,
      reset + reapply with fail-open ordering (SSH first, enable last).
- [x] shared declaration loader — read the consumer host-hardening package
      (the same pattern `gen-service-accounts` uses for `$sources`/`$accounts`).
- [x] `doc/system/host-hardening.md` — mechanism contract: declaration schema,
      reconcile semantics, fail-open ordering.
- [x] `doc/plans/2026-09-18-gen-firewall.md` — this doc.

## Open items

- **First live reconcile pending** — no `[prod]` roster is populated yet, so
  the first real apply is still ahead; that is also where `worker`-host
  no-inbound-rule behavior (cron/db-check loopback writes) gets verified.
