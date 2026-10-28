# GuardedInsert — replace the UNION ALL source with a two-statement write — Plan & Progress

Date: 2026-10-28
Repos: php_daas_framework (this repo).

## Problem

The `UNION ALL` source shape that `GuardedInsert` adopted is itself corrupt on
MariaDB at scale. `INSERT … SELECT … FROM (SELECT ? … FROM DUAL UNION ALL SELECT
?, … FROM DUAL) AS v` builds one derived-table branch per row, and once a single
parameter is large enough, MariaDB silently rebinds every placeholder that
follows it to `''`. On a `tinyint` column that surfaces as
`SQLSTATE[22007] 1366 Incorrect integer value: ''`; against an all-text table the
statement succeeds and stores `''` silently. At ~64 KB+ per parameter the symptom
escalates to `127 "Table file is corrupted"`.

`at row 1` in the message is misleading: it is the first materialized row of the
derived table, not a real input row.

## Evidence (reproduced)

- Trigger: a 200-branch chunk plus one parameter ≥ ~21.8 KB (20,988 B and 21,788 B
  pass; 21,828 B fails). Fewer branches tolerate more (150 rows / 24 KB ok; 10
  rows / 500 KB ok). Total statement volume is irrelevant (200 × 20 KB works).
- Plain multi-row `INSERT … VALUES (…),(…)` — `BatchInsert`'s shape — is
  unaffected: 200 rows with a 30 KB parameter, and a single parameter up to 4 MB,
  all insert cleanly. Past the packet limit it fails loud with `1153 Got a packet
  bigger than 'max_allowed_packet'`, never silently.
- First triggered in production by the consumer's historico backfill, whose batch
  crossed the threshold on a large JSON payload column.

## Decision

Change `GuardedInsert`'s per-chunk write to two statements:

1. `SELECT` the guard-key values that already exist for the chunk.
2. Filter them out in PHP.
3. Insert the survivors with a plain multi-row
   `INSERT … VALUES (…) … ON DUPLICATE KEY UPDATE col=col` (reusing `BatchInsert`'s
   safe shape).

The guard still runs before the computed id expression (`NEXT VALUE FOR`), so no
id burn. The `ON DUPLICATE KEY UPDATE` no-op stays as the concurrency-race
fallback (silent, one id burned per genuine race — already accepted).

## Why two-statement over a staging table

- Simplest change; reuses the proven-safe `VALUES` shape for the insert half.
- No temp-table lifecycle (create/drop/cleanup on failure) and no DDL per batch.
- Batch sizes are small (≈200), so the extra `SELECT` round-trip is negligible.
- Tradeoff: the race window widens slightly (two round-trips plus PHP between
  them) versus one statement. The race itself was already accepted; the widening
  is a marginal increase, not a new failure class.

## What this changes versus the current docblock

The current rationale — "use `UNION ALL` because MariaDB's `VALUES` table
constructor blanks placeholders" — remains true for the `FROM (VALUES ROW(…))`
constructor, but it was the wrong escape hatch. Plain `INSERT … VALUES` (the
`BatchInsert` shape) does not exhibit the blanking; it is the safe alternative.
The docblock should be rewritten to explain the two-statement form instead.

## What remains

- A byte cap on chunk size is still required, but only to stay under
  `max_allowed_packet` (a loud `1153`), not to avoid silent corruption.
- The fail-loud precondition and post-insert marker checks discussed during the
  diagnosis are no longer needed as primary defenses; they remain optional
  belt-and-suspenders.

## Changes

- [ ] `src/DatabaseOps/GuardedInsert.php` — replace the `UNION ALL` source with
      the two-statement write (SELECT keys → filter → VALUES insert).
- [ ] `src/DatabaseOps/BatchInsert.php` — no change (its shape is already safe).
- [ ] Docblock — replace the "UNION ALL vs VALUES constructor" rationale with the
      two-statement rationale.
- [ ] Tests — a large-payload batch inserts cleanly; a duplicate re-offer still
      does not advance the sequence; the race fallback still swallows duplicates.
