#!/usr/bin/env php
<?php

// Scans all PHP files under the consumer repo's src/ for functions decorated
// with both #[CronJob] and #[Agent] and prints a crontab to stdout, ready to
// be installed (e.g. /etc/cron.d/<app>-orchestrator by pf-deploy on every
// prod host, filtered by that host's tag list — see --host-tags below).
//
// Each #[CronJob] declares where it runs via a required `scope` argument:
//   - `host`       run on every prod host (host-maintenance jobs)
//   - `tag[:name]` run only on hosts whose [prod] entry carries that exact
//                  token (`worker`, `web`, `db:<name>`, …). Exact equality,
//                  no wildcards.
// `cron-manifest --host-tags <comma-list>` emits a job iff its `scope` is
// `host` or an exact element of the list; with no --host-tags it emits every
// job (unchanged dev/debug behavior).
//
// Config-driven, same config surfaces as `deploy`/`phprun`:
//   - REPO_PATH    from the repo-root .env (phprun contract); src/ is scanned
//                  relative to it and cron lines cd there.
//   - CRON_USER    from etc/deploy.conf; user the entries run as (default:
//                  root).
//   - CRON_NIX_BIN from etc/deploy.conf; dirs prepended to PATH by the
//                  entries (pf-deploy defaults it to
//                  $DEPLOY_TARGET_DIR/vendor/bin:$DEPLOY_NIX_RESULT_DIR/
//                  result/bin so both `phprun` and `php` resolve).
//
// Uses token_get_all() — no PHP code is executed, safe to scan any file.
// Both attributes must immediately precede the function with no blank lines
// or code between them. Schedule and scope values must use single quotes:
// #[CronJob(schedule: 'hourly', scope: 'worker')]. The order of #[CronJob]
// and #[Agent] relative to each other, and of the named arguments within
// #[CronJob], does not matter.

declare(strict_types=1);

$schedules = [
    '5min'    => '*/5 * * * *',
    'hourly'  => '0 * * * *',
    'daily'   => '@daily',
    'weekly'  => '@weekly',
    'monthly' => '@monthly',
];

$repo_root = getenv('REPO_PATH') ?: getcwd();
$cron_user = getenv('CRON_USER') ?: 'root';
$nix_bin   = getenv('CRON_NIX_BIN') ?: ((getenv('DEPLOY_NIX_RESULT_DIR') ?: '') . '/result/bin');

if ($nix_bin === '/result/bin') {
    fwrite(STDERR, "cron-manifest: set CRON_NIX_BIN or DEPLOY_NIX_RESULT_DIR (e.g. in etc/deploy.conf)\n");
    exit(1);
}

// --host-tags <comma-list>: emit only jobs whose scope is `host` or an exact
// element of the list. Absent -> emit all jobs. null means "flag not given".
$host_tags = null;
for ($i = 1; $i < $argc; $i++) {
    if ($argv[$i] === '--host-tags') {
        if ($i + 1 >= $argc) {
            fwrite(STDERR, "cron-manifest: --host-tags requires a comma-separated tag list\n");
            exit(1);
        }
        $host_tags = array_values(array_filter(
            array_map('trim', explode(',', $argv[$i + 1])),
            static fn (string $t): bool => $t !== ''
        ));
        $i++;
    } else {
        fwrite(STDERR, "cron-manifest: unknown argument '{$argv[$i]}'\n");
        exit(1);
    }
}

$src_dir = $repo_root . '/src';

$files   = new RecursiveIteratorIterator(new RecursiveDirectoryIterator($src_dir));
$entries = [];

foreach ($files as $file) {
    if ($file->getExtension() !== 'php') continue;

    $source = file_get_contents($file->getPathname());
    $tokens = token_get_all($source);
    $path   = ltrim(str_replace($repo_root, '', $file->getPathname()), '/');

    $pending_schedule = null;
    $pending_scope    = null;
    $has_agent        = false;

    foreach ($tokens as $i => $token) {
        if (!is_array($token)) continue;

        if ($token[0] === T_ATTRIBUTE) {
            $body = collect_attribute_body($tokens, $i);
            if (preg_match('/^CronJob\b/', $body)) {
                $pending_schedule = named_arg($body, 'schedule');
                $pending_scope    = named_arg($body, 'scope');
                if ($pending_scope === null) {
                    fwrite(STDERR, "cron-manifest: $path: #[CronJob] requires a 'scope' (e.g. #[CronJob(schedule: 'hourly', scope: 'worker')])\n");
                    exit(1);
                }
            } elseif (preg_match('/^Agent\b/', $body)) {
                $has_agent = true;
            }
        }

        if ($token[0] === T_FUNCTION && $pending_schedule !== null && $pending_scope !== null && $has_agent) {
            $func_name = next_string_token($tokens, $i);
            if ($func_name !== null) {
                $entries[] = [
                    'script'   => $path,
                    'agent'    => $func_name,
                    'schedule' => $pending_schedule,
                    'scope'    => $pending_scope,
                ];
            }
            $pending_schedule = null;
            $pending_scope    = null;
            $has_agent        = false;
        } elseif ($token[0] === T_FUNCTION) {
            $pending_schedule = null;
            $pending_scope    = null;
            $has_agent        = false;
        }
    }
}

if ($host_tags !== null) {
    $entries = array_values(array_filter($entries, static function (array $e) use ($host_tags): bool {
        return $e['scope'] === 'host' || in_array($e['scope'], $host_tags, true);
    }));
}

echo "NIX_BIN=$nix_bin" . PHP_EOL . PHP_EOL;
foreach ($entries as $e) {
    $sched = $e['schedule'];
    $cmd   = "phprun {$e['script']}:{$e['agent']}()";
    echo "$sched $cron_user /bin/sh -c 'export PATH=\"\$NIX_BIN:\$PATH\"; cd $repo_root && $cmd'" . PHP_EOL;
}

function collect_attribute_body(array $tokens, int $start): string
{
    $body = '';
    for ($i = $start + 1; $i < count($tokens); $i++) {
        $t = $tokens[$i];
        if ($t === ']') break;
        $body .= is_array($t) ? $t[1] : $t;
    }
    return trim($body);
}

function named_arg(string $body, string $name): ?string
{
    if (preg_match('/\b' . preg_quote($name, '/') . '\s*:\s*\'([^\']+)\'/', $body, $m)) {
        return $m[1];
    }
    return null;
}

function next_string_token(array $tokens, int $start): ?string
{
    for ($i = $start + 1; $i < count($tokens); $i++) {
        $t = $tokens[$i];
        if (is_array($t) && $t[0] === T_STRING) return $t[1];
        if (!is_array($t) && $t === '(') break;
    }
    return null;
}
