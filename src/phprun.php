<?php

declare(strict_types=1);

// `phprun` runner: execute one `#[Agent]` function from a consumer script,
// injecting the `#[Agent]` database connection as its first argument.
//
// The logic lives in phprun() rather than in this file's top level so a
// consumer (or a test) can drive a run in-process; this entrypoint only loads
// the consumer's autoloader and hands over the CLI selector.
//
// Instrumentation seam: a consumer may define two optional global functions,
// resolved through function_exists() so their absence changes nothing:
//
//   on_job_start(string $job, string $scope): void
//       Before the run, after the attributes are read.
//   on_job_finish(string $status, string $job, string $reason = ''): void
//       After the run: 'succeeded' on return, or 'failed' with the exception
//       message, called before the exception is rethrown.
//
// `$job` is "<script>:<function>" (the selector without its argument list);
// `$scope` is the `#[CronJob]` scope, or '' for a manual (unscheduled) agent.
// The framework stays storage-agnostic — it only reports run boundaries.

require 'vendor/autoload.php';

phprun($argv[1] ?? '');

function phprun(string $arg): void
{
    [$script, $func_call] = explode(':', $arg, 2);
    $func      = substr($func_call, 0, strpos($func_call, '('));
    $func_args = rtrim(substr($func_call, strpos($func_call, '(') + 1), ')');

    require $script;

    $rf    = new ReflectionFunction($func);
    $attrs = $rf->getAttributes(Utils\Agent::class);
    if (empty($attrs)) {
        fwrite(STDERR, "Error: '$func' in '$script' is not an #[Agent].\n");
        exit(1);
    }
    $agent = $attrs[0]->newInstance();

    // `scope` is only declared by a scheduled agent; a manual run has none and
    // reports it as an empty string.
    $cron_attrs = $rf->getAttributes(Utils\CronJob::class);
    $scope      = $cron_attrs === [] ? '' : $cron_attrs[0]->newInstance()->scope;

    $job = "{$script}:{$func}";

    if (function_exists('on_job_start')) {
        on_job_start($job, $scope);
    }

    try {
        $conn_arg = '';
        if ($agent->dbTarget !== null) {
            // The connection mode is EMA_TARGET's call: a sandbox target resolves the
            // local instance (no account), prod needs the declared service account —
            // Database::connectTo enforces that.
            $conn     = Utils\Connectivity\Database::connectTo($agent->dbTarget, $agent->dbAccount ?? '');
            $conn_arg = '$conn' . ($func_args !== '' ? ', ' : '');
        }

        printf('%s - Starting %s' . PHP_EOL, date('Y-m-d H:i:s'), $arg);
        eval("$func({$conn_arg}{$func_args});");
        printf('%s - Finished %s' . PHP_EOL, date('Y-m-d H:i:s'), $arg);

        if (function_exists('on_job_finish')) {
            on_job_finish('succeeded', $job);
        }
    } catch (Throwable $e) {
        if (function_exists('on_job_finish')) {
            on_job_finish('failed', $job, $e->getMessage());
        }
        throw $e;
    }
}
