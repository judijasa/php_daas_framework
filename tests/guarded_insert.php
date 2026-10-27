<?php

declare(strict_types=1);

// Tests for src/DatabaseOps/GuardedInsert.php.
//
// Standalone (no test framework): the test creates throwaway tables and a
// sequence in the connected schema, asserts the primitive's contracts, and
// drops them again.
//
// Run against a dev sandbox (provision it once with
// `ema sandbox srv/test-D0PR2OGMHXDSCAR3`):
//
//   EMA_TARGET=sandbox php tests/guarded_insert.php
//
// Or against any MariaDB, bypassing the ema resolver:
//
//   GUARDED_INSERT_TEST_DSN='mysql:unix_socket=/tmp/mysql.sock;dbname=test' \
//       php tests/guarded_insert.php

require_once __DIR__ . '/../vendor/autoload.php';

use Utils\Connectivity\Database;
use Utils\DatabaseOps\GuardedInsert;

$checks = 0;
$failures = 0;

/**
 * @param mixed $expected
 * @param mixed $actual
 */
$check = function (string $what, $expected, $actual) use (&$checks, &$failures): void {
    $checks++;
    if ($expected === $actual) {
        fwrite(STDOUT, "ok   {$what}" . PHP_EOL);
        return;
    }
    $failures++;
    fwrite(STDOUT, "FAIL {$what}" . PHP_EOL);
    fwrite(STDOUT, '     expected: ' . var_export($expected, true) . PHP_EOL);
    fwrite(STDOUT, '     actual:   ' . var_export($actual, true) . PHP_EOL);
};

$expect_error = function (string $what, string $needle, callable $fn) use (&$checks, &$failures): void {
    $checks++;
    try {
        $fn();
    } catch (RuntimeException $e) {
        if (str_contains($e->getMessage(), $needle)) {
            fwrite(STDOUT, "ok   {$what}" . PHP_EOL);
            return;
        }
        $failures++;
        fwrite(STDOUT, "FAIL {$what}" . PHP_EOL);
        fwrite(STDOUT, '     expected message containing: ' . $needle . PHP_EOL);
        fwrite(STDOUT, '     actual: ' . $e->getMessage() . PHP_EOL);
        return;
    }
    $failures++;
    fwrite(STDOUT, "FAIL {$what}" . PHP_EOL);
    fwrite(STDOUT, '     expected RuntimeException containing: ' . $needle . PHP_EOL);
    fwrite(STDOUT, '     no exception was thrown' . PHP_EOL);
};

$dsn = getenv('GUARDED_INSERT_TEST_DSN');
if ($dsn !== false && $dsn !== '') {
    $conn = new PDO(
        $dsn,
        getenv('GUARDED_INSERT_TEST_USER') ?: 'root',
        getenv('GUARDED_INSERT_TEST_PASS') ?: '',
        [
            PDO::ATTR_ERRMODE => PDO::ERRMODE_EXCEPTION,
            PDO::ATTR_DEFAULT_FETCH_MODE => PDO::FETCH_ASSOC,
            PDO::ATTR_EMULATE_PREPARES => false,
        ]
    );
} else {
    $conn = Database::connectTo(getenv('GUARDED_INSERT_TEST_DB') ?: 'test', 'demo');
}

$sequence = 'gi_test_seq';
$tables = [
    'gi_test_plain',
    'gi_test_ai',
    'gi_test_no_default',
    'gi_test_composite',
    'gi_test_prefix',
];

$drop = static function () use ($conn, $sequence, $tables): void {
    $conn->exec("DROP SEQUENCE IF EXISTS `{$sequence}`");
    foreach ($tables as $table) {
        $conn->exec("DROP TABLE IF EXISTS `{$table}`");
    }
};

$ids = static function (string $table) use ($conn): array {
    $rows = $conn->query("SELECT `id` FROM `{$table}` ORDER BY `id`")->fetchAll(PDO::FETCH_COLUMN);

    return array_map('intval', $rows);
};

$lastval = static function () use ($conn, $sequence): int {
    return (int) $conn->query("SELECT LASTVAL(`{$sequence}`)")->fetchColumn();
};

$auto_increment = static function (string $table) use ($conn): int {
    return (int) $conn->query(
        'SELECT AUTO_INCREMENT FROM information_schema.TABLES'
        . " WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = '{$table}'"
    )->fetchColumn();
};

$drop();

try {
    // 1. The guard key is asserted against the live schema.
    $conn->exec(
        'CREATE TABLE `gi_test_plain` ('
        . ' `id` INT NOT NULL,'
        . ' `code` VARCHAR(32) NOT NULL,'
        . ' `name` VARCHAR(64) NOT NULL,'
        . ' UNIQUE KEY `uq_code` (`code`),'
        . ' KEY `idx_name` (`name`)'
        . ')'
    );
    $conn->exec("CREATE OR REPLACE SEQUENCE `{$sequence}` AS INT");

    $expect_error(
        'a non-unique key column is rejected',
        'not a declared UNIQUE key',
        static fn () => GuardedInsert::insert(
            $conn,
            'gi_test_plain',
            ['id', 'code', 'name'],
            ['name'],
            [['a', 'A']],
            10,
            ['id' => "NEXT VALUE FOR {$sequence}"]
        )
    );
    $expect_error(
        'a key set wider than the unique key is rejected',
        'not a declared UNIQUE key',
        static fn () => GuardedInsert::insert(
            $conn,
            'gi_test_plain',
            ['id', 'code', 'name'],
            ['code', 'name'],
            [['a', 'A']],
            10,
            ['id' => "NEXT VALUE FOR {$sequence}"]
        )
    );
    $expect_error(
        'a computed key column is rejected',
        'cannot be computed',
        static fn () => GuardedInsert::insert(
            $conn,
            'gi_test_plain',
            ['id', 'code', 'name'],
            ['id'],
            [['a', 'A']],
            10,
            ['id' => "NEXT VALUE FOR {$sequence}"]
        )
    );

    // 2. Duplicate re-offers do not advance the sequence.
    GuardedInsert::insert(
        $conn,
        'gi_test_plain',
        ['id', 'code', 'name'],
        ['code'],
        [['a', 'A'], ['b', 'B'], ['c', 'C']],
        2,
        ['id' => "NEXT VALUE FOR {$sequence}"]
    );
    $check('the first guarded insert allocates ids 1,2,3', [1, 2, 3], $ids('gi_test_plain'));
    $check('the sequence is at 3 after the first insert', 3, $lastval());

    GuardedInsert::insert(
        $conn,
        'gi_test_plain',
        ['id', 'code', 'name'],
        ['code'],
        [['a', 'A'], ['b', 'B'], ['c', 'C']],
        2,
        ['id' => "NEXT VALUE FOR {$sequence}"]
    );
    $check('a duplicate re-offer inserts no rows', [1, 2, 3], $ids('gi_test_plain'));
    $check('a duplicate re-offer leaves the sequence at 3', 3, $lastval());

    GuardedInsert::insert(
        $conn,
        'gi_test_plain',
        ['id', 'code', 'name'],
        ['code'],
        [['d', 'D']],
        10,
        ['id' => "NEXT VALUE FOR {$sequence}"]
    );
    $check('the next new row gets id 4, not 7', [1, 2, 3, 4], $ids('gi_test_plain'));
    $check('the sequence advanced to 4 only for the new row', 4, $lastval());

    // 3. AUTO_INCREMENT mode: a duplicate re-offer does not advance the
    //    counter. One-row batches keep the initial allocation contiguous;
    //    MariaDB's INSERT ... SELECT may reserve extra values per multi-row
    //    statement, which is separate from the re-offer burn.
    $conn->exec(
        'CREATE TABLE `gi_test_ai` ('
        . ' `id` INT AUTO_INCREMENT PRIMARY KEY,'
        . ' `code` VARCHAR(32) NOT NULL,'
        . ' `name` VARCHAR(64) NOT NULL,'
        . ' UNIQUE KEY `uq_code` (`code`)'
        . ')'
    );
    foreach ([['a', 'A'], ['b', 'B'], ['c', 'C']] as $row) {
        GuardedInsert::insert(
            $conn,
            'gi_test_ai',
            ['code', 'name'],
            ['code'],
            [$row],
            1
        );
    }
    $check('auto-increment mode allocates ids 1,2,3', [1, 2, 3], $ids('gi_test_ai'));
    $check('the auto-increment counter is at 4', 4, $auto_increment('gi_test_ai'));

    GuardedInsert::insert(
        $conn,
        'gi_test_ai',
        ['code', 'name'],
        ['code'],
        [['a', 'A'], ['b', 'B'], ['c', 'C']],
        3
    );
    $check('a duplicate re-offer inserts no rows', [1, 2, 3], $ids('gi_test_ai'));
    $check('a duplicate re-offer leaves the auto-increment counter at 4', 4, $auto_increment('gi_test_ai'));

    GuardedInsert::insert(
        $conn,
        'gi_test_ai',
        ['code', 'name'],
        ['code'],
        [['d', 'D']],
        1
    );
    $check('the next auto-increment row gets id 4', [1, 2, 3, 4], $ids('gi_test_ai'));

    // 4. A no-default id fails loud when the id is not computed.
    $conn->exec(
        'CREATE TABLE `gi_test_no_default` ('
        . ' `id` INT NOT NULL,'
        . ' `code` VARCHAR(32) NOT NULL,'
        . ' UNIQUE KEY `uq_code` (`code`)'
        . ')'
    );
    $expect_error(
        'a no-default id fails loud when the id is not computed',
        "doesn't have a default value",
        static fn () => GuardedInsert::insert(
            $conn,
            'gi_test_no_default',
            ['code'],
            ['code'],
            [['a']],
            10
        )
    );

    // 5. A composite unique key guards on every column.
    $conn->exec(
        'CREATE TABLE `gi_test_composite` ('
        . ' `a` INT NOT NULL,'
        . ' `b` INT NOT NULL,'
        . ' `v` VARCHAR(16) NOT NULL,'
        . ' UNIQUE KEY `uq_ab` (`a`, `b`)'
        . ')'
    );
    GuardedInsert::insert(
        $conn,
        'gi_test_composite',
        ['a', 'b', 'v'],
        ['a', 'b'],
        [[1, 2, 'x'], [1, 3, 'y'], [1, 2, 'dup']],
        10
    );
    $check(
        'a composite guard filters a duplicate in the same batch',
        2,
        (int) $conn->query('SELECT COUNT(*) FROM `gi_test_composite`')->fetchColumn()
    );
    $check(
        'the composite guard keeps the first value',
        'x',
        (string) $conn->query('SELECT `v` FROM `gi_test_composite` WHERE `a` = 1 AND `b` = 2')->fetchColumn()
    );

    GuardedInsert::insert(
        $conn,
        'gi_test_composite',
        ['a', 'b', 'v'],
        ['a', 'b'],
        [[1, 2, 'again'], [1, 4, 'z']],
        10
    );
    $check(
        'a composite guard filters a duplicate from an earlier batch',
        3,
        (int) $conn->query('SELECT COUNT(*) FROM `gi_test_composite`')->fetchColumn()
    );

    // 6. A prefix unique key cannot be mirrored by a full-value guard.
    $conn->exec(
        'CREATE TABLE `gi_test_prefix` ('
        . ' `code` VARCHAR(64) NOT NULL,'
        . ' UNIQUE KEY `uq_code` (`code`(8))'
        . ')'
    );
    $expect_error(
        'a prefix unique key is rejected',
        'prefix length',
        static fn () => GuardedInsert::insert(
            $conn,
            'gi_test_prefix',
            ['code'],
            ['code'],
            [['abcdefgh-1']],
            10
        )
    );
} finally {
    $drop();
}

fwrite(STDOUT, PHP_EOL . ($failures === 0
    ? "All {$checks} checks passed." . PHP_EOL
    : "{$failures} of {$checks} checks failed." . PHP_EOL));

exit($failures === 0 ? 0 : 1);
