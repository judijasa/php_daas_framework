# Replica schema identity: instance vs database — Plan & Progress

Date: 2026-10-05
Repos: php_daas_framework (this repo), ema (upstream, `../ema`).

## Decision

ema splits the two identities a connection section shares into one string
today: the section header names the **instance** (the running mariadbd), while
a new `DBNAME` key names the **schema** the instance serves (default: the
header). This repo's connection layer still treats the header as the database
name, so a replica — which serves the primary's schema under a plain name
(`simo`) distinct from its own instance name — would connect to a schema the
replica host never materializes. This repo adopts the split on the reader
side: `Database::connectTo` / `connectAs` / `connectSandbox` keep taking the
instance name to key the section, but the DSN's `dbname=` becomes the
section's `DBNAME` (falling back to the header).

The mechanism originates in
`../ema/doc/plans/2026-10-05-replica-schema-identity.md`; this repo changes the
connector, the grants substitution, and the docs/templates that describe the
section model.

## Changes

### php_daas_framework (this repo)

- [x] `src/Connectivity/Database.php` — `buildDsn` (64) and the sandbox DSN in
      `connectSandbox` (163): the `dbname=` value is the loaded section's
      `DBNAME` (falling back to the header), not the header itself.
      `loadSection` keeps keying the section by header, and the
      `$dbname` / `$account` arguments keep naming the instance.
- [x] `bin/gen-service-accounts` — the `{{dbname}}` substitution (344) fills
      the target database's `dbname` (read from the `srv/<name>-<GUID>`
      package's `DatabaseConfig`), not the `<name>` argument, which keeps
      naming the instance (grants-package glob + `ema` section). A replica
      package's `dbname` is the primary's schema, so its grants target that
      schema while `gen-service-accounts <replica>` still locates
      `pkg/<replica>.roles-*`.
- [x] `etc/reuter.ini.template` (3) — "the section header IS the database
      name" becomes "the section header names the instance; `DBNAME` names the
      schema (default: the header)".
- [x] `doc/system/ema.md` (124) — the `[mydb]` section sample and the
      "section header IS the dbname" wording: the header names the instance,
      `DBNAME` the schema.
- [x] `doc/system/agents.md` (24) — `dbTarget` reads as the instance name (the
      section header), not the database name; the schema follows from `DBNAME`.
- [x] `doc/system/consumer-config.md` (62) — the sandbox-resolution wording:
      the app layer resolves the sandbox ini by instance name; the schema still
      comes from `DBNAME`.
- [x] `doc/system/replica-bootstrap.md` — workflow step 3 drops the
      `replicate-rewrite-db = <primary>-><replica>` clause: ema no longer
      rewrites; the replica serves the primary's schema under its own name.

## Open items

- **`dbTarget` / `dbAccount` naming** — the argument names keep the `db`
  prefix while now meaning "instance"; cosmetic, no behavioural change.
- **`connectTo` takes the instance, not the schema** — callers that today pass
  a database name and expect it to double as the section key are unchanged only
  where the schema is still named after the instance; under the plain-schema
  convention (`simo` served by `simo0`/`simo1`) the schema always comes from
  `DBNAME`, so callers must pass the instance name and the section must carry
  `DBNAME` on both.
