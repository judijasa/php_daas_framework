<?php

declare(strict_types=1);

// Unit tests for src/host_resolver.php — the shared name<->IP host lookup.
//
// Standalone (no test framework): the resolver is a handful of pure functions
// over two consumer-owned private files, so the tests build those two files in
// a throwaway directory and assert on what the lookup answers — including the
// two spellings of one host, an unknown spelling, a host that is known but not
// in [prod], and an IP the mapping has no name for. The bin/pf-host CLI (what
// the bash CLIs call) is exercised over the same fixtures.
//
// Run from the repo root:  php tests/host_resolver.php   (or `make test`)

require_once __DIR__ . '/../src/host_resolver.php';

$checks = 0;
$failures = 0;

/**
 * Assert one expectation and print the outcome.
 *
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

// Run bin/pf-host from $root; returns [exit code, combined output].
//
// @return array{int,string}
function run_pf_host(string $root, string $args): array
{
    $cmd = 'cd ' . escapeshellarg($root)
        . ' && ' . escapeshellarg(PHP_BINARY)
        . ' ' . escapeshellarg(dirname(__DIR__) . '/bin/pf-host')
        . ' ' . $args . ' 2>&1';
    $output = [];
    $code = 0;
    exec($cmd, $output, $code);

    return [$code, implode(PHP_EOL, $output)];
}

// Fixtures: one host with both spellings in [prod], one [prod] host the
// mapping has no name for, and one mapped host that is not in [prod].
$root = sys_get_temp_dir() . '/host_resolver_test_' . bin2hex(random_bytes(6));
mkdir($root . '/etc', 0700, true);
file_put_contents(
    $root . '/etc/hosts',
    "# dev host mapping\n"
    . "10.147.18.10 simo0\n"
    . "10.147.18.11 simo1   # the db box\n"
    . "10.147.18.12 stray\n"
);
file_put_contents(
    $root . '/etc/machines.ini',
    "[prod]\n"
    . "10.147.18.10=db:simo, web\n"
    . "10.147.18.11=worker\n"
    . "10.147.18.13=worker\n"
);

// Name -> canonical host (name + IP).
$error = null;
$check(
    'a short name resolves to the canonical host',
    ['name' => 'simo0', 'ip' => '10.147.18.10'],
    resolve_host('simo0', $root, $error)
);
$check('resolving a known name reports no error', null, $error);

// IP -> the same canonical host.
$error = null;
$check(
    'a ZeroTier IP resolves to the same canonical host',
    ['name' => 'simo0', 'ip' => '10.147.18.10'],
    resolve_host('10.147.18.10', $root, $error)
);
$check('resolving a known IP reports no error', null, $error);

// A [prod] host the optional mapping has no name for: the IP is still the
// canonical host, only its name half is unknown.
$error = null;
$check(
    'a [prod] IP with no name in the mapping resolves without a name',
    ['name' => null, 'ip' => '10.147.18.13'],
    resolve_host('10.147.18.13', $root, $error)
);

// Unknown spelling: no name in the mapping, so there is no host at all.
$error = null;
$check('an unknown name does not resolve', null, resolve_host('simo9', $root, $error));
$check(
    'an unknown name reports the missing mapping',
    true,
    is_string($error) && str_contains($error, 'etc/hosts')
);

// Known host, but not a deploy target.
$error = null;
$check('a host outside [prod] does not resolve', null, resolve_host('stray', $root, $error));
$check(
    'a host outside [prod] reports the roster',
    true,
    is_string($error) && str_contains($error, '[prod]')
);

// The CLI the bash CLIs call, over the same fixtures.
[$code, $out] = run_pf_host($root, 'simo0');
$check('pf-host prints the ZeroTier IP', [0, '10.147.18.10'], [$code, $out]);
[$code, $out] = run_pf_host($root, '--name 10.147.18.11');
$check('pf-host --name prints the short name', [0, 'simo1'], [$code, $out]);
[$code, $out] = run_pf_host($root, 'stray');
$check('pf-host fails on a host outside [prod]', [1, true], [$code, str_contains($out, '[prod]')]);

unlink($root . '/etc/hosts');
unlink($root . '/etc/machines.ini');
rmdir($root . '/etc');
rmdir($root);

if ($failures === 0) {
    fwrite(STDOUT, PHP_EOL . "{$checks} checks passed" . PHP_EOL);
    exit(0);
}
fwrite(STDOUT, PHP_EOL . "{$failures} of {$checks} checks FAILED" . PHP_EOL);
exit(1);
