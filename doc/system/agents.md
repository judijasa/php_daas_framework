# `#[Agent]` and `#[CronJob]` — attribute reference

Scheduled, database-backed agents are declared with two attributes placed
immediately before a function, with no blank lines or code between them (in
either order):

```php
#[CronJob(schedule: '*/5 * * * *', scope: 'worker')]
#[Agent(dbTarget: 'test', dbAccount: 'demo')]
function my_agent($conn): void
{
    // ...
}
```

## `#[Agent]`

Declares a function as a runnable agent for `phprun` and holds its DB
connectivity. `#[Agent]` is for DB connectivity only — where a job runs is
`#[CronJob]`'s `scope`, not `#[Agent]`.

| Argument    | Type      | Required             | Meaning |
|-------------|-----------|----------------------|---------|
| `dbTarget`  | `?string` | no                   | The instance name (the `reuter.ini` section header). `phprun` resolves it through `Database::connectTo` and injects the connection as the call's first argument: under `EMA_TARGET=sandbox` it is the local `var/sandbox/<name>-<GUID>/reuter.ini` instance, under `EMA_TARGET=prod` (also unset/empty) the `[<instance>]` section of the resolved `reuter.ini`. The schema the instance serves is the section's `DBNAME` (default: the header), never the target string. |
| `dbAccount` | `?string` | under `EMA_TARGET=prod` | The service-account name whose `<ACCOUNT>_PASSWORD` key `Database::connectAs` reads from that `reuter.ini` section. Prod-only: sandbox mode ignores it and connects as `root` over the instance's socket. |

An agent with no database (e.g. a host-maintenance job) uses
`#[Agent(dbTarget: null)]`. A bare `dbTarget` without a `dbAccount` is
therefore valid in dev — the dev `.env` sets `EMA_TARGET=sandbox`, so the
target resolves to the local sandbox instance — while prod rejects the
missing account. The mode switch and the sandbox resolution contract are in
[ema.md](ema.md).

## `#[CronJob]`

Schedules an `#[Agent]` for `cron-manifest`. `schedule` is *when* the job
runs; `scope` is *where* it runs.

| Argument   | Type     | Required | Meaning |
|------------|----------|----------|---------|
| `schedule` | `string` | yes      | The cron schedule expression for the entry. |
| `scope`    | `string` | **yes**  | Where the job runs: `host` (every prod host) or an exact `tag[:name]` token from `etc/machines.ini`. |

`scope` has no default — a `#[CronJob]` without it is a hard error, rejected
by both `cron-manifest` and the pre-commit attribute check. There is no
`none` scope: a job is disabled by commenting out its `#[CronJob]`
attribute.

### Scope grammar and matching

| scope value      | matches |
|------------------|---------|
| `host`           | every prod host |
| `worker`         | hosts with the bare `worker` token |
| any `tag[:name]` | hosts whose roster entry carries that exact token |

`cron-manifest --host-tags <comma-list>` (the filter `deploy` runs on
every host, passing that host's own normalized token list) emits a job iff:

- `scope === 'host'`, or
- `scope` is an exact element of the comma list.

Matching is exact token equality — no wildcards. `worker` is not
special-cased: a job scoped `worker` runs only on hosts whose roster entry
carries the bare `worker` token. With no `--host-tags`, `cron-manifest` emits
every job (dev/debug behavior).

## Instrumentation hooks

`phprun` reports each run's boundaries to two **optional** global functions,
resolved with `function_exists()` — a consumer that defines neither behaves
exactly as before:

```php
function on_job_start(string $job, string $scope): void
function on_job_finish(string $status, string $job, string $reason = ''): void
```

| Hook | When | Arguments |
|------|------|-----------|
| `on_job_start` | once, before the run | `$job` — `<script>:<function>`; `$scope` — the `#[CronJob]` scope, or `''` for a manual (unscheduled) agent |
| `on_job_finish` | once, after the run | `$status` — `succeeded` or `failed`; `$job`; `$reason` — the exception message on failure |

On failure the finish hook runs before the exception is rethrown, so the
process still exits non-zero. A run that dies without unwinding (a signal, or
`exit()` mid-run) emits `on_job_start` only — the missing finish is itself the
signal. The framework stores nothing and knows no transport: it only announces
boundaries, leaving recording and schema to the consumer.
