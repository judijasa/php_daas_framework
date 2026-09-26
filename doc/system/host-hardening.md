# Host hardening — tag-driven ufw firewall

Date: 2026-09-18
Scope: how this framework turns a consumer's host-hardening declaration into
the desired `ufw` rule set for every prod host, then applies it as root with a
fail-open ordering. The framework owns the mechanism (`bin/gen-firewall`); the
consumer owns the data (the declaration, the `etc/machines.ini` `[prod]`
roster, the `db:<name>` ports in `etc/reuter.ini`, and the ZeroTier range).
sshd hardening is out of scope here — it stays a consumer-side manual
pre-deployment step.

## Model

One desired rule set per host, computed as the **order-independent set union**
of that host's tags. Tags only add allows; the baseline owns the defaults and
any denies. The full set is computed *before* the host is touched, then applied
fail-open: `ufw --force reset` (firewall off), default policies, the allow
rules with SSH first, and `ufw --force enable` last — so a mid-way failure
leaves the host reachable and re-running converges.

The CLI runs from the consumer checkout that holds `etc/machines.ini` and
`etc/reuter.ini` (the deploy/dev machine) and applies each host over
`ssh root@<host>`. It defaults to `--dry-run`; pass `--apply` to reconcile.

    gen-firewall [host|all] [-a|--apply] [-n|--dry-run] [-h|--help]

| Argument | Meaning |
|---|---|
| `host` | one `[prod]` host, as its short name or its ZeroTier IP (see `doc/system/host-resolution.md`). |
| `all` | reconcile every `[prod]` host (the default). |
| `-a`, `--apply` | actually apply over `ssh root@<host>` (default is dry-run). |
| `-n`, `--dry-run` | print the computed rules without applying (the default). |

### Declaration

The consumer's `etc/host-hardening.php` carries the declaration (all
consumer data — no tag name, port or range is hardcoded). It is
private data: the real file lives in the consumer's private config repo and
the consumer places it at `etc/host-hardening.php` (see
`doc/system/consumer-config.md`). The consumer's committed
`etc/host-hardening.php.template` is a copy of this framework's template with
placeholder values — never the real deployment values, which would put them in
the public history:

    $zerotierRange = '10.147.x.0/24';            // CIDR, or an 'x' template
    $tagRules      = array(
        'web' => array('80/tcp', '443/tcp'),
        'pub' => array(array('rule' => '443/tcp', 'gate' => 'cloud')),
    );

- `$zerotierRange` scopes the baseline SSH and `db:<name>` rules. A concrete
  CIDR is used verbatim; an `'x'` template (e.g. `10.147.x.0/24`) resolves its
  private third octet from the consumer's private `etc/hosts` (`ip name`
  mapping) — the range is never hardcoded here.
- `$tagRules` maps a consumer-owned tag to its allow rules. A rule is either
  `'PORT/PROTO'` (a public allow, e.g. `80/tcp`) or
  `array('rule' => 'PORT/PROTO', 'gate' => 'cloud')` (applied only when the
  host itself reports as virtualized). Any rule that is not a valid
  `PORT/PROTO` is reported and ignored.
- The `gate => 'cloud'` condition is mechanism-owned, not declared: at
  reconcile time the CLI asks the target host whether it is virtualized
  (`systemd-detect-virt`, over the same `ssh root@<host>` it already uses) and
  applies the gated rules only if it is. A hypervisor or container means the
  host's path to its ZeroTier peers is not a plain LAN path — the condition the
  gate is after — and nothing cloud-specific is configured, so a provider
  moving or dropping its metadata service cannot affect the reconcile. The
  probe fails safe: systemd absent, an unreachable host or no answer all read
  as *not* virtualized, so the gated rule is skipped (with a warning) and the
  rest of the host is reconciled normally.

### Roster and built-in tags

`etc/machines.ini` `[prod]` maps each ZeroTier host to comma-separated
`tag[:name]` tokens — the same roster grammar `pf-roster` parses, so the deploy
chain and this CLI share one reading of the roster. `gen-firewall` understands
two built-in tags; every other tag must map to a rule in `$tagRules` (an
unmapped tag warns and adds no allow):

- **`db:<name>`** — allow `<reuter.ini[name].PORT>/tcp` from the ZeroTier range
  (the database's own TCP port, recorded from `ema create`). An empty name or a
  missing `PORT` is a hard error.
- **`worker`** — no inbound rule: cron writes loopback/local.

Every host gets the **baseline** regardless of tags:

    ufw default deny incoming
    ufw default allow outgoing
    ufw allow from <range> to any port 22 proto tcp   # SSH, first among allows

## Reconcile semantics

For each target host the CLI computes the full step list — baseline first,
then each tag's allows, then `enable` last — and then either prints it
(dry-run) or applies it. Apply is a `set -e` shell script piped to
`ssh root@<host> bash -s`: `ufw --force reset` first, then the ordered steps.
The cloud gate is resolved once per host before anything runs; if the host
does not report as virtualized, the gated rules are omitted and the host is
otherwise reconciled as normal.

## Notes

- **Fail-open, converge on re-run** — reset (firewall off) is the first step
  and `enable` the last, so a failure mid-way leaves the host reachable; the
  order-independent desired set means re-running always converges.
- **Tags only add allows** — the baseline owns the defaults and any denies;
  the desired set is the union of a host's tags, never a subtraction.
- **Declaration schema is permissive to read** — `package_declaration()`
  coerces whatever `etc/host-hardening.php` sets into a typed shape and
  reports invalid rules rather than aborting on them.
- **No `[prod]` roster yet** — the first live `--apply` is still ahead; until
  then `gen-firewall` only ever dry-runs or fails loudly on a missing roster.
