# Machine certs and client SSL

Date: 2026-09-29
Scope: how a consumer's MariaDB service accounts can be created with
`REQUIRE X509` (the server verifies the client presents a trusted certificate)
and how the app layer and the operator present that certificate. The framework
owns the mechanism — one SSL directory holding `client.crt` + `client.key`,
both paths derived from a single `SSL_DIR` value, and the `gen-cert` CLI that
mints and installs the material — while the values stay consumer data (the
directory, the team hostname→IP registry). The CA and the `REQUIRE X509`
declaration are consumer/sibling-repo concerns, out of scope here.

## Quick setup

```bash
# 1. dev machine, once: record this machine's hostname -> ZeroTier IP in
#    etc/team.ini (private, git-ignored). SSL_DIR defaults to the committed
#    etc/dev.default.conf; set it in the optional etc/dev.conf override only to
#    diverge. Example etc/team.ini entry inside any [member] section:
#      <hostname> = <ZeroTier IP>
#    Example etc/dev.conf override:
#      export SSL_DIR=/home/<user>/.<app>/ssl

# 2. dev machine, repo root: mint a key + CSR (CN = this machine's pinned name,
#    derived by matching its local IPv4 against etc/team.ini)
gen-cert

# 3. offline CA machine: sign the CSR — a standard `openssl ca` operation
#    (the CA key never leaves that machine). The CA workflow (sign, revoke,
#    CRL) is consumer data: each consumer documents its own CA in its private
#    docs.

# 4. dev machine, repo root: install the signed cert + local key and write the
#    ~/.my.cnf.d/<app>.cnf drop-in
gen-cert install client.crt
```

## Model

One client certificate per **machine**, not per account: the same `client.crt`
is presented for every service account that machine connects as. `REQUIRE X509`
is a membership gate — it only checks that the presented certificate chains to
a CA the server trusts; it never matches the subject. So the certificate's CN
is an audit identity (which machine connected), not an authorization check.
Identity — which account a machine may use — is the `<ACCOUNT>_PASSWORD` key,
exactly as before; per-project isolation comes from each project having its
own CA (the subject does not scope anything).

The cert material is one directory holding two files, both derived from the
single `SSL_DIR` value:

- `<SSL_DIR>/client.crt` — the public certificate (shipped back from the CA).
- `<SSL_DIR>/client.key` — the private key (never leaves the machine; mode
  `0600`; the CSR embeds the public half, and the CA signs that).

The framework never hardcodes an SSL dir or a cert path: `SSL_DIR` is always
consumer data, supplied by a different source per machine (see below).

## gen-cert

`bin/gen-cert` is the machine-side helper (dev-only, run from the repo root).
`<app>` is never typed: it is `basename "$PWD"`, which names the drop-in
(`~/.my.cnf.d/<app>.cnf`) and, as a tag, the managed region inside it.

### `gen-cert` — mint

Argument-free. It mints `client.key` + `client.csr` in the current directory:

```bash
openssl req -new -newkey rsa:2048 -nodes \
    -keyout client.key -out client.csr -subj "/CN=<name>"
```

The CN is not an argument and carries no GUID: it is the `etc/team.ini`
hostname whose value equals one of this machine's own local IPv4 addresses
(the machine's ZeroTier IP). If no local address matches a hostname→IP entry,
`gen-cert` fails loudly — the machine must be on ZeroTier to use the cert
anyway. The CN is the machine's pinned name (from the team registry), never
the ZeroTier node name.

`client.key` never leaves the machine; only `client.csr` is sent to the
operator for signing.

### `gen-cert install <client.crt>` — install

Places the operator-returned cert and the local key into `$SSL_DIR/`
(`client.crt` mode `0644`, `client.key` mode `0600`) and idempotently writes a
drop-in at `~/.my.cnf.d/<app>.cnf`:

```text
# generated: <app>-client-ssl
# Managed by gen-cert - do not edit; re-run the generator instead.
[client]
ssl-cert=<SSL_DIR>/client.crt
ssl-key=<SSL_DIR>/client.key
# end: <app>-client-ssl
```

It also ensures `~/.my.cnf` carries `!includedir <home>/.my.cnf.d/` (at the
top, exactly once, never clobbering other content). `!includedir` does not
expand `~`, so `gen-cert` writes the absolute path.

The drop-in is written with the same tagged-region + atomic-rename idiom as
`bin/gen-ssh-config` (see `doc/system/ssh-config.md`): the tagged region is
replaced in place on every run, anything outside the tags is left untouched,
and a begin tag without its matching end tag aborts instead of truncating.

The SSL dir is read from `etc/dev.default.conf`'s `SSL_DIR` (overridden by
`etc/dev.conf`; sourced), never hardcoded.

## The offline CA step

`gen-cert` never touches the CA key. The signing is a standard `openssl ca`
operation the operator runs on the offline CA machine, which holds the CA
certificate (a placeholder ships in `etc/team-ca.crt`) and the CA key (never
committed, never networked). The public cert returns; the private key never
moves.

The full CA workflow — signing, revocation, and CRL generation (`openssl ca
-revoke` / `-gencrl`) — is consumer data: `openssl ca` needs the `index.txt`
ledger the consumer's CA maintains, and each consumer documents its own CA in
its private docs. This framework only mints the CSR and installs the returned
cert; it never runs the CA.

## App-layer wiring

`Utils\Connectivity\Database::connectAs()` reads `SSL_DIR` and, when set,
passes `PDO::MYSQL_ATTR_SSL_CERT` (`<SSL_DIR>/client.crt`) and
`PDO::MYSQL_ATTR_SSL_KEY` (`<SSL_DIR>/client.key`). Unset → plain TCP, exactly
as before. The attributes are added in the prod/TCP path only: the dev sandbox
connects as `root` over the local unix socket and never applies TLS.

## Config surfaces

| Machine | Value | Source | Consumer |
|---|---|---|---|
| prod host | `SSL_DIR` | `etc/deploy.conf` `DEPLOY_SSL_DIR` → `gen-env` → `.env` | the PHP app layer |
| dev machine | `SSL_DIR` | `etc/dev.default.conf` `SSL_DIR` (overridden by `etc/dev.conf`) → sourced by `gen-cert` | `gen-cert` |

The name is the same on both sides — `SSL_DIR` — because it is the same
mechanism (one cert directory) with different consumer data on different
machines and different config sources. `DEPLOY_SSL_DIR` is optional: a
consumer without client-cert auth omits it, and `gen-env` omits `SSL_DIR`, so
the app stays on plain TCP. `gen-cert` reads `SSL_DIR` from
`etc/dev.default.conf` (overridden by `etc/dev.conf`) directly (see
`doc/system/consumer-config.md`).

The private key is never shipped via config or `DEPLOY_PRIVATE_FILES`; only the
public cert travels back to the host.

## Out of scope / follow-ups

- The `REQUIRE X509` declaration and the CA are consumer/sibling-repo data, not
  this framework's mechanism.
- Server-side `ssl-ca`/`ssl-crl` emission (the `[mysqld]` half) lives in the
  sibling `ema` repo: the host-level `etc/ema.default.conf` it reads (overridden
  by the optional `etc/ema.conf`; `ssl-ca` and `ssl-crl`, absolute paths on the
  host) has its consumer-facing shape in this repo's `etc/ema.default.conf` — a
  committed default that rides with the repo, so it is no longer named in
  `DEPLOY_PRIVATE_FILES` (see `doc/system/consumer-config.md`).
- Client-side **server** verification (the client checking the server's cert via
  `ssl-ca`) is deferred, not dismissed — it needs CA-signed *server* certs.
- Revocation: the server half (checking a client cert against a CRL) is the
  sibling `ema` repo's `ssl-crl`; the CA-side CRL generation is consumer data
  (a standard `openssl ca` workflow), documented by each consumer in its
  private docs.
