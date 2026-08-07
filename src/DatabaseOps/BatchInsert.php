<?php

namespace Utils\DatabaseOps;

use PDO;

class BatchInsert
{
    public static function insert(PDO $conn, string $table, array $columns, array $rows, int $batch_size): void
    {
        if (empty($rows)) return;

        $col_list    = implode(', ', $columns);
        $placeholder = '(' . implode(', ', array_fill(0, count($columns), '?')) . ')';

        foreach (array_chunk($rows, $batch_size) as $chunk) {
            $placeholders = implode(', ', array_fill(0, count($chunk), $placeholder));
            $sql          = "INSERT INTO {$table} ({$col_list}) VALUES {$placeholders} ON DUPLICATE KEY UPDATE {$columns[0]} = {$columns[0]}";
            $conn->prepare($sql)->execute(array_merge(...$chunk));
        }
    }
}
