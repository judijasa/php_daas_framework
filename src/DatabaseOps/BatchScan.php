<?php

namespace Utils\DatabaseOps;

use Utils\Logger;

class BatchScan
{
    /*
    Make sure the query has the overall structure:

        SELECT ... FROM ...
        WHERE id >= :curr_id AND id < :next_id
          AND abs(id) % :div = :mod
    */
    public static function scan(
        $conn,
        string $table_name,
        string $query,
        int $batch_size,
        string $cursor_key,
        callable $process_batch,
        ?int $max_time = 60 * 50,
        int $mod = 0,
        int $div = 1
    ): void {
        $stmt = $conn->query("SELECT min(id) FROM {$table_name}");
        $lower_bound = (int) $stmt->fetchColumn();

        $cursorseq = new CursorSeq($conn, $cursor_key);
        $curr_id = $cursorseq->get_cursor($lower_bound, $mod, $div);

        $stmt = $conn->query("SELECT max(id) FROM {$table_name}");
        $max_id = (int) $stmt->fetchColumn();

        Logger::info("BatchScan [{$cursor_key}]: cursor={$curr_id}, max_id={$max_id}");

        if ($curr_id > $max_id) {
            Logger::info("BatchScan [{$cursor_key}]: nothing to process (cursor past max_id)");
            return;
        }

        $is_time_unlimited = ($max_time === null);
        $start_time = microtime(true);
        $total_rows = 0;
        $batch_num = 0;

        while ($curr_id <= $max_id && ($is_time_unlimited || microtime(true) - $start_time < $max_time)) {
            $next_id = $curr_id + $div * $batch_size;
            $stmt = $conn->prepare($query);
            $stmt->bindValue(':curr_id', $curr_id);
            $stmt->bindValue(':next_id', $next_id);
            $stmt->bindValue(':mod', $mod);
            $stmt->bindValue(':div', $div);
            $stmt->execute();
            $rows = $stmt->fetchAll();
            $batch_num++;
            Logger::info("BatchScan [{$cursor_key}]: batch {$batch_num} (ids {$curr_id}–{$next_id}): " . count($rows) . " rows");
            $process_batch($rows);
            $total_rows += count($rows);
            $curr_id = $next_id;
            $cursorseq->set_cursor($curr_id, $mod, $div);
        }

        Logger::info("BatchScan [{$cursor_key}]: done, {$total_rows} total rows across {$batch_num} batches");
    }
}
