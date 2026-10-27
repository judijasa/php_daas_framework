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
     * Per batch this is a guarded `INSERT ... SELECT`:
     *
     *     INSERT INTO t (id, code, nombre)
     *     SELECT NEXT VALUE FOR t_id_seq, v.code, v.nombre
     *     FROM (SELECT ? AS code, ? AS nombre FROM DUAL
     *           UNION ALL SELECT ?, ? FROM DUAL) AS v
     *     WHERE NOT EXISTS (SELECT 1 FROM t g WHERE g.code = v.code)
     *     ON DUPLICATE KEY UPDATE t.code = t.code
     *
     * The source is a UNION ALL of SELECTs rather than `VALUES (?,?),...`:
     * MariaDB's VALUES table constructor silently binds every placeholder to
     * the empty string under PDO's native prepares, which would insert empty
     * rows and then filter the rest as duplicates.
     *
     * The `WHERE NOT EXISTS` guard filters duplicates before the SELECT list
     * is evaluated, so a computed id expression (`NEXT VALUE FOR`) is never
     * evaluated for a row that already exists. The no-op
     * `ON DUPLICATE KEY UPDATE` remains as the concurrency-race fallback.
     *
     * `$rows` supplies values only for the non-computed columns, in the order
     * those columns appear in `$columns`; `$computed` columns are written by
     * SQL expression instead.
     *
     * With `id` absent from `$columns` and no `$computed` entry, the id is
     * left to AUTO_INCREMENT. The guard still prevents duplicate re-offers
     * from advancing the counter, though MariaDB's `INSERT ... SELECT` may
     * reserve extra values per statement (its own bulk-allocation behavior).
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

        $select_list = [];
        foreach ($columns as $column) {
            $select_list[] = array_key_exists($column, $computed)
                ? $computed[$column]
                : 'v.' . self::quoteIdentifier($column);
        }
        $select = implode(', ', $select_list);

        $guard = implode(' AND ', array_map(
            static fn (string $column): string =>
                'g.' . self::quoteIdentifier($column) . ' = v.' . self::quoteIdentifier($column),
            $keyColumns
        ));
        $noop = self::quoteIdentifier($table_name) . '.' . self::quoteIdentifier($keyColumns[0]);
        $first_row_select = 'SELECT ' . implode(', ', array_map(
            static fn (string $column): string => '? AS ' . self::quoteIdentifier($column),
            $value_columns
        )) . ' FROM DUAL';
        $other_row_select = 'SELECT '
            . implode(', ', array_fill(0, count($value_columns), '?'))
            . ' FROM DUAL';

        foreach (array_chunk($rows, $batch_size) as $chunk) {
            foreach ($chunk as $row) {
                if (!array_is_list($row) || count($row) !== count($value_columns)) {
                    throw new RuntimeException(
                        "GuardedInsert into table '{$table}': each row must be a list of "
                        . count($value_columns) . ' values for (' . implode(', ', $value_columns) . ').'
                    );
                }
            }

            $source_selects = [$first_row_select];
            for ($i = 1, $row_count = count($chunk); $i < $row_count; $i++) {
                $source_selects[] = $other_row_select;
            }
            $source = implode(' UNION ALL ', $source_selects);
            $sql = "INSERT INTO {$quoted_table} ({$insert_columns}) "
                . "SELECT {$select} FROM ({$source}) AS v "
                . "WHERE NOT EXISTS (SELECT 1 FROM {$quoted_table} g WHERE {$guard}) "
                . "ON DUPLICATE KEY UPDATE {$noop} = {$noop}";

            try {
                $conn->prepare($sql)->execute(array_merge(...$chunk));
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
