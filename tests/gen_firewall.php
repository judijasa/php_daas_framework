<?php

declare(strict_types=1);

// Tests for bin/gen-firewall: declaration + roster -> desired ufw rule set.
//
// Standalone (no test framework): each case writes a throwaway etc/
// (machines.ini + host-hardening.php), dry-runs the CLI against it, and
// asserts the computed rules. Dry-run only — no ssh, no ufw, and no
// reuter.ini (the db:<name> ports are explicit rules now, so their absence
// must not matter).
//
// Run: php tests/gen_firewall.php

$bin = __DIR__ . '/../bin/gen-firewall';

$checks = 0;
$failures = 0;

$check = static function (string $what, bool $ok) use (&$checks, &$failures): void {
    $checks++;
    fwrite(STDOUT, ($ok ? 'ok   ' : 'FAIL ') . $what . PHP_EOL);
    if (!$ok) {
        $failures++;
    }
};

/**
 * Dry-run gen-firewall against a throwaway consumer checkout and return the
 * combined stdout+stderr.
 *
 * @param array<string,string> $files etc/ file name => contents
 * @return array{code: int, output: string}
 */
$dry_run = static function (array $files, string $target = 'all') use ($bin): array {
    $dir = sys_get_temp_dir() . '/gen_firewall_test_' . bin2hex(random_bytes(6));
    if (!mkdir($dir . '/etc', 0777, true) && !is_dir($dir . '/etc')) {
        throw new RuntimeException("could not create {$dir}/etc");
    }
    foreach ($files as $name => $contents) {
        file_put_contents($dir . '/etc/' . $name, $contents);
    }
    $cwd = getcwd();
    if ($cwd === false) {
        $cwd = '.';
    }
    chdir($dir);
    $lines = [];
    $code = 0;
    exec(
        escapeshellarg(PHP_BINARY) . ' ' . escapeshellarg($bin) . ' ' . escapeshellarg($target) . ' --dry-run 2>&1',
        $lines,
        $code
    );
    chdir($cwd);
    foreach (array_keys($files) as $name) {
        @unlink($dir . '/etc/' . $name);
    }
    @rmdir($dir . '/etc');
    @rmdir($dir);
    return ['code' => $code, 'output' => implode("\n", $lines)];
};

$declaration = "<?php\n"
    . "\$zerotierRange = '10.99.233.0/24';\n"
    . "\$sshRule = '22/tcp';\n"
    . "\$tagRules = array(\n"
    . "    'db:simo0' => array('38857/tcp'),\n"
    . "    'db:simo1' => array('45765/tcp'),\n"
    . ");\n";

// A db host's db:<name> tag resolves to its explicit declared port. No
// reuter.ini is written, so the removed built-in lookup cannot be masking it.
$result = $dry_run([
    'machines.ini' => "10.99.233.181=db:simo0, worker\n10.99.233.242=db:simo1\n",
    'host-hardening.php' => $declaration,
]);

$check('db host dry-run exits 0 with no reuter.ini present', $result['code'] === 0);
$check('db:simo0 opens its declared 38857/tcp from the range', str_contains($result['output'], 'ufw allow from 10.99.233.0/24 to any port 38857 proto tcp'));
$check('db:simo1 opens its declared 45765/tcp from the range', str_contains($result['output'], 'ufw allow from 10.99.233.0/24 to any port 45765 proto tcp'));
$check('baseline SSH rule present', str_contains($result['output'], 'ufw allow from 10.99.233.0/24 to any port 22 proto tcp'));

// An undeclared db:<name> tag is a warning that adds no allow, not the old
// hard error on a missing reuter.ini PORT.
$result = $dry_run([
    'machines.ini' => "10.99.233.242=db:simo2\n",
    'host-hardening.php' => $declaration,
]);

$check('an undeclared db:<name> tag warns and still exits 0', $result['code'] === 0);
$check('the undeclared tag reports "maps to no rule"', str_contains($result['output'], "'db:simo2' maps to no rule (adds no allow)"));

// A missing $sshRule is a hard error: SSH is the first allow, and a plan
// without it would lock the operator out under default deny incoming.
$result = $dry_run([
    'machines.ini' => "10.99.233.242=web\n",
    'host-hardening.php' => "<?php\n\$zerotierRange = '10.99.233.0/24';\n\$tagRules = array();\n",
]);

$check('a missing $sshRule fails loudly (non-zero exit)', $result['code'] !== 0);
$check('the missing $sshRule error names $sshRule', str_contains($result['output'], '$sshRule'));

fwrite(STDOUT, PHP_EOL . ($failures === 0
    ? "All {$checks} checks passed." . PHP_EOL
    : "{$failures} of {$checks} checks failed." . PHP_EOL));

exit($failures === 0 ? 0 : 1);
