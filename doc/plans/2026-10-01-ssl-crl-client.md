# Client cert docs point at the consumer CA/CRL workflow — Plan & Progress

Date: 2026-10-01
Repos: php_daas_framework (this repo); ema (upstream)

## Decision

The framework's `doc/system/machine-certs.md` stops embedding a concrete
`openssl x509 -req` signing command and instead points at a standard
`openssl ca` workflow. `openssl ca` (unlike `-CAcreateserial`) keeps the
`index.txt` ledger a CRL is generated from, so the same CA can later revoke a
leaked certificate and emit a CRL. The CA workflow — sign, revoke, CRL — is
consumer data, documented by each consumer in its own private docs; the
framework only mints the CSR and installs the returned cert. No framework code
changes: `gen-cert` already never touches the CA key.

## Changes

### php_daas_framework (this repo)

- [x] (doc) — `doc/system/machine-certs.md`: replace the `openssl x509 -req`
      quick-setup step and the "offline CA step" section with a standard
      `openssl ca` description; refresh the out-of-scope bullets (server-side
      `ssl-ca`/`ssl-crl` emission is ema's; CA-side CRL generation is consumer
      data).
- [x] `etc/ema.default.conf` — document `ssl-crl` (mirrors ema's reader change);
      commented `ssl-crl` example.

## Open items

- **No `ssl-crl` default** — this repo ships no CA and no CRL; the consumer owns
  the trust anchor, so `ssl-crl` stays commented in `etc/ema.default.conf`.
