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
| `dbTarget`  | `?string` | no                   | The database name (`[<dbname>]` section in `reuter.ini`). When set, `phprun` opens a connection and injects it as the call's first argument. |
| `dbAccount` | `?string` | when `dbTarget` is set | The service-account name whose `<ACCOUNT>_PASSWORD` key `Database::connectAs` reads from that `reuter.ini` section. |

An agent with no database (e.g. a host-maintenance job) uses
`#[Agent(dbTarget: null)]`.

## `#[CronJob]`

Schedules an `#[Agent]` for `cron-manifest`. `schedule` is *when* the job
runs; `scope` is *where* it runs.

| Argument   | Type     | Required | Meaning |
|------------|----------|----------|---------|
| `schedule` | `string` | yes      | The cron schedule expression for the entry. |
| `scope`    | `string` | **yes**  | Where the job runs: `host` (every prod host) or an exact `tag[:name]` token from `etc/machines.ini [prod]`. |

`scope` has no default — a `#[CronJob]` without it is a hard error, rejected
by both `cron-manifest` and the pre-commit attribute check. There is no
`none` scope: a job is disabled by commenting out its `#[CronJob]`
attribute.

### Scope grammar and matching

| scope value      | matches |
|------------------|---------|
| `host`           | every `[prod]` host |
| `worker`         | hosts with the bare `worker` token |
| any `tag[:name]` | hosts whose `[prod]` entry carries that exact token |

`cron-manifest --host-tags <comma-list>` (the filter `pf-deploy.sh` runs on
every host, passing that host's own normalized token list) emits a job iff:

- `scope === 'host'`, or
- `scope` is an exact element of the comma list.

Matching is exact token equality — no wildcards. `worker` is not
special-cased: a job scoped `worker` runs only on hosts whose `[prod]` entry
carries the bare `worker` token. With no `--host-tags`, `cron-manifest` emits
every job (dev/debug behavior).
