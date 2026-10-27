# GuardedInsert — a write primitive that does not burn id allocations — Plan & Progress

Date: 2026-10-27
Repos: php_daas_framework (this repo).

## Problem

`BatchInsert::insert()` emits `INSERT … VALUES … ON DUPLICATE KEY UPDATE col=col`.
The no-op update clause makes duplicates harmless, but InnoDB reserves an
`AUTO_INCREMENT` value for every offered row *before* the unique-key check. A
caller that re-offers existing rows therefore burns ids at the rate of attempts,
not rows — and a small id type exhausts even with few actual rows. (Postgres
`GENERATED … AS IDENTITY` has the same failure: the underlying sequence advances
on conflict.)

## Decision

Add `Utils\DatabaseOps\GuardedInsert` beside `BatchInsert` in
`src/DatabaseOps/`. It is a separate primitive — `BatchInsert` is left unchanged —
and it filters duplicates inside the write, so id allocation happens only for rows
that are actually new.

```php
GuardedInsert::insert(
    PDO $conn,
    string $table,
    array $columns,       // every column written, including 'id' when sequence-managed
    array $keyColumns,    // MANDATORY: the unique-key columns to guard on, subset of $columns
    array $rows,          // values for the non-computed columns only
    int $batch_size,
    array $computed = [], // column => SQL expression, e.g. ['id' => 'NEXT VALUE FOR t_id_seq']
): void
```

- `$keyColumns` is required — no default, no backward-compatibility shim. The
  primitive asserts against the live schema (`information_schema.STATISTICS`) that
  `$keyColumns` is exactly a declared `UNIQUE` key; a mismatch fails loud.
- Per chunk the write is a guarded `INSERT … SELECT`:

```sql
INSERT INTO t (id, code, nombre)
SELECT NEXT VALUE FOR t_id_seq, v.code, v.nombre
FROM (VALUES (?,?),(?,?)) AS v(code, nombre)
WHERE NOT EXISTS (SELECT 1 FROM t g WHERE g.code = v.code)
ON DUPLICATE KEY UPDATE t.code = t.code
```

  `WHERE NOT EXISTS` is the guard: source rows that already exist are filtered
  before the `SELECT` list is evaluated, so `NEXT VALUE FOR` never runs for them.
  The `ON DUPLICATE KEY UPDATE` no-op (qualified with the target table) stays as the
  concurrency-race fallback.

- **Id source.** `$computed['id'] = 'NEXT VALUE FOR <seq>'` allocates the id
  explicitly and only for new rows; an empty `$computed` with `id` absent from
  `$columns` leaves it to `AUTO_INCREMENT`. Both modes are supported.

## Why both the guard and a sequence

The guard is what stops the waste: with it, `AUTO_INCREMENT` alone is already
correct. The sequence adds maintainability the guard cannot: the counter becomes an
explicit object that can be reset to `MAX(id)+1`, shared across tables,
pre-allocated in ranges, or set to reuse gaps. Without the guard a sequence burns
exactly like `AUTO_INCREMENT`; without the sequence the counter cannot be reset or
shared. They compose — neither substitutes for the other.

## Verified on MariaDB 11.8

- `NEXT VALUE FOR seq` and `NEXTVAL(seq)` both parse; `CREATE SEQUENCE … AS INT` and
  `CREATE OR REPLACE SEQUENCE` are supported.
- The guarded form yields tight ids (1,2,3,4) with no advance across five re-offer
  rounds.
- A no-default `id` makes a naive writer fail with error 1364, so misuse is loud.
- **PDO native prepares.** `VALUES (?,?),…` silently binds every placeholder to
  `''` under `PDO::ATTR_EMULATE_PREPARES => false`, so the implemented source is
  `SELECT ? AS col, … FROM DUAL UNION ALL SELECT ?, … FROM DUAL`. The guard and
  `ON DUPLICATE KEY UPDATE` shape are unchanged.
- **AUTO_INCREMENT caveat.** In the no-`$computed` mode MariaDB may reserve extra
  `AUTO_INCREMENT` values per `INSERT … SELECT` statement (bulk allocation), so
  ids can have gaps even though re-offers no longer advance the counter. The
  sequence mode is the tight-id mode.

## Changes

- [x] `src/DatabaseOps/GuardedInsert.php` — the primitive above, PHPStan level 5.
- [x] `README.md` — list `GuardedInsert` alongside `BatchInsert`.
- [x] Tests: keys asserted against the schema; a duplicate re-offer does not advance
      a sequence; a no-default id fails loud.

## Open items

- **Race residual** — a concurrent insert that loses the race still consumed its
  `NEXT VALUE FOR` value (one rare gap); accepted, since it is not the systematic
  re-offer burn.
- **`$computed` seam** — `column => expression` is the proposed shape; refine during
  implementation if a simpler form fits.
