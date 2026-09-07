<?php

declare(strict_types=1);

require 'vendor/autoload.php';

use Utils\Agent;
use Utils\Connectivity\Database;
use Utils\DatabaseOps\BatchInsert;
use Utils\DatabaseOps\BatchScan;
use Utils\DatabaseOps\CursorSeq;
use Utils\Logger;

/**
 * End-to-end smoke test for the DB layer.
 *
 * Provision first (see README "Quick test: PHP–MariaDB integration with ema"):
 *   ema sandbox srv/test-D0PR2OGMHXDSCAR3
 *   bin/phprun 'src/scripts/demo/db_smoke.php:main()'
 *
 * Re-running is safe: rows accumulate in `items` and BatchScan resumes
 * from its persisted cursor.
 */
#[Agent(dbTarget: 'test', dbAccount: 'demo')]
function main($conn): void
{
    // 1) Connectivity — $conn is a live PDO connection created by
    //    Utils\Connectivity\Database::connectAs('test', 'demo') from the [test]
    //    section of the resolved reuter.ini (injected by the runner).

    // 2) BatchInsert — persist 10 rows into `items` in chunks of 5.
    $rows = [];
    for ($i = 0; $i < 10; $i++) {
        $rows[] = ['item ' . ($i + 1), date('Y-m-d H:i:s')];
    }
    BatchInsert::insert($conn, 'items', ['name', 'created_at'], $rows, 5);
    Logger::info('BatchInsert: inserted 10 rows into items');

    // 3) CursorSeq — read-or-init a cursor, then advance it.
    $seq = new CursorSeq($conn, 'demo_cursor');
    $cursor = $seq->get_cursor(0);
    Logger::info("CursorSeq: demo_cursor = {$cursor}");
    $seq->set_cursor(42);
    Logger::info('CursorSeq: demo_cursor advanced to 42');

    // 4) BatchScan — reprocess `items` in batches of 3, resuming from its
    //    own cursor (cursor_key 'demo_scan_cursor').
    $total = 0;
    BatchScan::scan(
        $conn,
        'items',
        "SELECT id, name FROM items WHERE id >= :curr_id AND id < :next_id AND abs(id) % :div = :mod",
        3,
        'demo_scan_cursor',
        function ($batch) use (&$total) {
            $total += count($batch);
            Logger::info('BatchScan: batch of ' . count($batch));
        },
        null,
        0,
        1
    );
    Logger::info("BatchScan: processed {$total} rows total");
}
