<?php

namespace Utils\DatabaseOps;

use PDO;
use PDOException;
use RuntimeException;

class GuardedInsert
{
    /**
     * Insert rows, filtering out any whose guard key already exists.
     *
     * Per batch this is two statements:
     *
     *     SELECT code FROM t WHERE code IN (?, ?, ...)
     *     INSERT INTO t (id, code, nombre)
     *       VALUES (NEXT VALUE FOR t_id_seq, ?, ?), ...
     *       ON DUPLICATE KEY UPDATE t.code = t.code
     *
     * The first statement finds which chunk rows already exist, PHP drops
     * them, and the second inserts the survivors with a plain multi-row
     * VALUES list. The guard therefore runs before the computed id expression
     * (`NEXT VALUE FOR`) is evaluated, so a re-offer never allocates an id.
     *
     * A VALUES list is used deliberately instead of an `INSERT ... SELECT`
     * over a `UNION ALL` derived table: MariaDB corrupts the parameter stream
     * of a many-branch `UNION ALL` derived table once a single parameter is
     * large (~22 KB at 200 branches), silently rebinding the placeholders that
     * follow it to `''`. A VALUES list has no derived table and is unaffected.
     *
     * The `ON DUPLICATE KEY UPDATE` no-op remains as the concurrency-race
     * fallback: a concurrent insert that wins the race between the two
     * statements burns one id silently, which is the accepted residual.
     *
     * `$rows` supplies values only for the non-computed columns, in the order
     * those columns appear in `$columns`; `$computed` columns are written by
     * SQL expression instead.
     *
     * With `id` absent from `$columns` and no `$computed` entry, the id is
     * left to AUTO_INCREMENT. The guard still prevents duplicate re-offers
     * from advancing the counter, though a multi-row `INSERT ... VALUES` may
     * reserve a contiguous range for its own rows.
     *
     * `$keyColumns` must be exactly one declared unique key (including a
     * PRIMARY key) on the live table. The assertion fails loud on a mismatch:
     * a guard on a non-unique column set would insert duplicates, and a guard
     * on a subset of a composite key would let conflicts reach the
     * `ON DUPLICATE KEY UPDATE` path, burning ids.
     *
     * @param list<string>          $columns    every column written, in insert order
     * @param list<string>          $keyColumns the unique-key columns to guard on, a subset of $columns
     * @param list<array<mixed>>    $rows       one list of values per row, for the non-computed columns only
     * @param array<string, string> $computed   column => raw SQL expression (e.g. NEXT VALUE FOR t_id_seq)
     */
    public static function insert(
        PDO $conn,
        string $table,
        array $columns,
        array $keyColumns,
        array $rows,
        int $batch_size,
        array $computed = []
    ): void {
        self::assertShape($table, $columns, $keyColumns, $computed, $batch_size);
        self::assertUniqueKey($conn, $table, $keyColumns);

        $value_columns = array_values(array_filter(
            $columns,
            static fn (string $column): bool => !array_key_exists($column, $computed)
        ));

        $quoted_table = self::quoteTable($table);
        $table_name = self::tableName($table);
        $insert_columns = implode(', ', array_map(
            static fn (string $column): string => self::quoteIdentifier($column),
            $columns
        ));

        // $rows supply values only for the non-computed columns; map each key
        // column to its position in that value list so the guard can read the
        // key values back out of each row.
        $value_index = array_flip($value_columns);
        $key_indexes = array_map(
            static fn (string $column): int => $value_index[$column],
            $keyColumns
        );

        $noop = self::quoteIdentifier($table_name) . '.' . self::quoteIdentifier($keyColumns[0]);

        foreach (array_chunk($rows, $batch_size) as $chunk) {
            foreach ($chunk as $row) {
                if (!array_is_list($row) || count($row) !== count($value_columns)) {
                    throw new RuntimeException(
                        "GuardedInsert into table '{$table}': each row must be a list of "
                        . count($value_columns) . ' values for (' . implode(', ', $value_columns) . ').'
                    );
                }
            }

            // 1. Guard before allocation: find which chunk rows already exist.
            $existing = self::selectExistingKeys(
                $conn, $quoted_table, $keyColumns, $key_indexes, $chunk
            );

            // 2. Drop the rows whose guard key is already present.
            $survivors = [];
            foreach ($chunk as $row) {
                $key_values = array_map(
                    static fn (int $index) => $row[$index],
                    $key_indexes
                );
                if (!isset($existing[self::keySignature($key_values)])) {
                    $survivors[] = $row;
                }
            }
            if ($survivors === []) {
                continue;
            }

            // 3. Insert the survivors with a plain multi-row VALUES list. A
            //    VALUES list has no derived table, so it does not hit MariaDB's
            //    many-branch UNION ALL corruption; the ON DUPLICATE KEY UPDATE
            //    no-op stays as the concurrency-race fallback.
            $tuples = [];
            $params = [];
            foreach ($survivors as $row) {
                $parts = [];
                foreach ($columns as $column) {
                    if (array_key_exists($column, $computed)) {
                        $parts[] = $computed[$column];
                    } else {
                        $parts[] = '?';
                        $params[] = $row[$value_index[$column]];
                    }
                }
                $tuples[] = '(' . implode(', ', $parts) . ')';
            }
            $sql = "INSERT INTO {$quoted_table} ({$insert_columns}) VALUES "
                . implode(', ', $tuples)
                . " ON DUPLICATE KEY UPDATE {$noop} = {$noop}";

            try {
                $conn->prepare($sql)->execute($params);
            } catch (PDOException $e) {
                throw new RuntimeException(
                    "GuardedInsert into table '{$table}' (columns: {$insert_columns}; keys: "
                    . implode(', ', $keyColumns) . ") failed: {$e->getMessage()}",
                    0,
                    $e
                );
            }
        }
    }

    /**
     * Return the guard-key signatures already present in $table among $chunk.
     *
     * The lookup is a plain `SELECT ... WHERE (key...) IN (...)` (or a bare
     * `IN` list for a single key column) so it uses the declared unique index
     * and never builds a derived table.
     *
     * @param list<string>       $keyColumns
     * @param list<int>          $keyIndexes  index of each key column within a row
     * @param list<array<mixed>> $chunk       rows, values for the non-computed columns only
     * @return array<string, true>
     */
    private static function selectExistingKeys(
        PDO $conn,
        string $quoted_table,
        array $keyColumns,
        array $keyIndexes,
        array $chunk
    ): array {
        $key_list = implode(', ', array_map(
            static fn (string $column): string => self::quoteIdentifier($column),
            $keyColumns
        ));

        $params = [];
        if (count($keyColumns) === 1) {
            $placeholders = array_fill(0, count($chunk), '?');
            foreach ($chunk as $row) {
                $params[] = $row[$keyIndexes[0]];
            }
            $sql = "SELECT {$key_list} FROM {$quoted_table} WHERE {$key_list} IN ("
                . implode(', ', $placeholders) . ')';
        } else {
            $tuples = [];
            foreach ($chunk as $row) {
                $tuple = [];
                foreach ($keyIndexes as $index) {
                    $tuple[] = '?';
                    $params[] = $row[$index];
                }
                $tuples[] = '(' . implode(', ', $tuple) . ')';
            }
            $sql = "SELECT {$key_list} FROM {$quoted_table} WHERE ({$key_list}) IN ("
                . implode(', ', $tuples) . ')';
        }

        $existing = [];
        $stmt = $conn->prepare($sql);
        $stmt->execute($params);
        foreach ($stmt->fetchAll(PDO::FETCH_NUM) as $row) {
            $existing[self::keySignature($row)] = true;
        }

        return $existing;
    }

    /**
     * Canonical signature for a guard-key value list.
     *
     * Values are cast to string so the PHP-side key matches what the SELECT
     * returns regardless of driver type handling (PDO may hand back an integer
     * column as int or as string). NULL is kept distinct from ''.
     *
     * @param list<mixed> $values
     */
    private static function keySignature(array $values): string
    {
        $parts = [];
        foreach ($values as $value) {
            if ($value === null) {
                $parts[] = 'n';
                continue;
            }
            $s = (string) $value;
            $parts[] = strlen($s) . ':' . $s;
        }

        return implode('', $parts);
    }


    /**
     * @param list<string>          $columns
     * @param list<string>          $keyColumns
     * @param array<string, string> $computed
     */
    private static function assertShape(
        string $table,
        array $columns,
        array $keyColumns,
        array $computed,
        int $batch_size
    ): void {
        if ($table === '') {
            throw new RuntimeException('GuardedInsert: table name must not be empty.');
        }
        if ($batch_size < 1) {
            throw new RuntimeException("GuardedInsert into table '{$table}': batch_size must be at least 1.");
        }
        if ($columns === []) {
            throw new RuntimeException("GuardedInsert into table '{$table}': columns must not be empty.");
        }
        foreach ($columns as $column) {
            if ($column === '') {
                throw new RuntimeException(
                    "GuardedInsert into table '{$table}': every column must be a non-empty string."
                );
            }
        }
        if (count($columns) !== count(array_unique($columns))) {
            throw new RuntimeException("GuardedInsert into table '{$table}': columns must not repeat.");
        }
        if ($keyColumns === []) {
            throw new RuntimeException("GuardedInsert into table '{$table}': keyColumns is mandatory.");
        }
        foreach ($keyColumns as $column) {
            if ($column === '') {
                throw new RuntimeException(
                    "GuardedInsert into table '{$table}': every key column must be a non-empty string."
                );
            }
        }
        if (count($keyColumns) !== count(array_unique($keyColumns))) {
            throw new RuntimeException("GuardedInsert into table '{$table}': keyColumns must not repeat.");
        }

        $missing_keys = array_diff($keyColumns, $columns);
        if ($missing_keys !== []) {
            throw new RuntimeException(
                "GuardedInsert into table '{$table}': key column(s) "
                . implode(', ', $missing_keys) . ' are not in columns.'
            );
        }

        $computed_columns = array_map('strval', array_keys($computed));
        $unknown_computed = array_diff($computed_columns, $columns);
        if ($unknown_computed !== []) {
            throw new RuntimeException(
                "GuardedInsert into table '{$table}': computed column(s) "
                . implode(', ', $unknown_computed) . ' are not in columns.'
            );
        }

        $computed_keys = array_intersect($keyColumns, $computed_columns);
        if ($computed_keys !== []) {
            throw new RuntimeException(
                "GuardedInsert into table '{$table}': key column(s) "
                . implode(', ', $computed_keys) . ' cannot be computed; the guard needs source values.'
            );
        }

        foreach ($computed as $column => $expression) {
            if (trim($expression) === '') {
                throw new RuntimeException(
                    "GuardedInsert into table '{$table}': computed expression for '{$column}'"
                    . ' must be a non-empty string.'
                );
            }
        }

        if (count($computed) === count($columns)) {
            throw new RuntimeException(
                "GuardedInsert into table '{$table}': at least one column must be a source value, not computed."
            );
        }
    }

    /**
     * Assert that $keyColumns is exactly one declared unique key on the table.
     *
     * @param list<string> $keyColumns
     */
    private static function assertUniqueKey(PDO $conn, string $table, array $keyColumns): void
    {
        [$schema, $table_name] = self::splitTable($table);

        $sql = 'SELECT INDEX_NAME, COLUMN_NAME, SUB_PART FROM information_schema.STATISTICS'
            . ' WHERE TABLE_NAME = :table AND NON_UNIQUE = 0';
        if ($schema === null) {
            $sql .= ' AND TABLE_SCHEMA = DATABASE()';
        } else {
            $sql .= ' AND TABLE_SCHEMA = :schema';
        }
        $sql .= ' ORDER BY INDEX_NAME, SEQ_IN_INDEX';

        $stmt = $conn->prepare($sql);
        $stmt->bindValue(':table', $table_name, PDO::PARAM_STR);
        if ($schema !== null) {
            $stmt->bindValue(':schema', $schema, PDO::PARAM_STR);
        }
        $stmt->execute();

        /** @var array<string, array{columns: list<string>, prefix: bool}> $indexes */
        $indexes = [];
        foreach ($stmt->fetchAll(PDO::FETCH_ASSOC) as $row) {
            $index_name = (string) $row['INDEX_NAME'];
            if (!isset($indexes[$index_name])) {
                $indexes[$index_name] = ['columns' => [], 'prefix' => false];
            }
            $indexes[$index_name]['columns'][] = (string) $row['COLUMN_NAME'];
            if ($row['SUB_PART'] !== null) {
                $indexes[$index_name]['prefix'] = true;
            }
        }

        $wanted = $keyColumns;
        sort($wanted);

        foreach ($indexes as $index_name => $index) {
            $found = $index['columns'];
            sort($found);
            if ($found !== $wanted) {
                continue;
            }
            if ($index['prefix']) {
                throw new RuntimeException(
                    "GuardedInsert into table '{$table}': unique key '{$index_name}' uses a prefix length;"
                    . ' the guard compares full values and cannot mirror it.'
                );
            }
            return;
        }

        $available = [];
        foreach ($indexes as $index_name => $index) {
            $available[] = "{$index_name}(" . implode(', ', $index['columns']) . ')';
        }
        throw new RuntimeException(
            "GuardedInsert into table '{$table}': key columns (" . implode(', ', $keyColumns)
            . ') are not a declared UNIQUE key.'
            . ($available === []
                ? ' The table declares no UNIQUE key.'
                : ' Declared UNIQUE keys: ' . implode(', ', $available) . '.')
        );
    }

    /**
     * @return array{0: ?string, 1: string}
     */
    private static function splitTable(string $table): array
    {
        $parts = explode('.', $table);
        if (count($parts) > 2) {
            throw new RuntimeException(
                "GuardedInsert: table name '{$table}' must be 'table' or 'schema.table'."
            );
        }
        foreach ($parts as $part) {
            if ($part === '') {
                throw new RuntimeException(
                    "GuardedInsert: table name '{$table}' must be 'table' or 'schema.table'."
                );
            }
        }

        if (count($parts) === 2) {
            return [$parts[0], $parts[1]];
        }
        return [null, $parts[0]];
    }

    private static function tableName(string $table): string
    {
        [, $name] = self::splitTable($table);
        return $name;
    }

    private static function quoteTable(string $table): string
    {
        [$schema, $name] = self::splitTable($table);
        return $schema === null
            ? self::quoteIdentifier($name)
            : self::quoteIdentifier($schema) . '.' . self::quoteIdentifier($name);
    }

    private static function quoteIdentifier(string $identifier): string
    {
        return '`' . str_replace('`', '``', $identifier) . '`';
    }
}
