# Shared HTTP client for crawlers — Plan & Progress

Date: 2026-10-18
Repos: php_daas_framework (this repo).

## Decision

Add a small cURL-based `Utils\Crawler\HttpClient` beside `CasperTrio` for
consumers that fetch server-rendered HTML and therefore don't need a
JS-capable crawler. Targets can have misconfigured certificates, so the client
takes an ignore-SSL option alongside the usual timeout, follow-redirects, and
custom headers. A `download()`/binary seam is included, so a
consumer can fetch binary documents without a refactor. `CasperTrio`
(PhantomJS) stays for JS-rendered targets.

No new dependency: cURL is a PHP extension; the class lives under the existing
`Utils\` PSR-4 root (`src/`), beside `src/Crawler/CasperTrio.php`.

## Changes

- [x] `src/Crawler/HttpClient.php` — `Utils\Crawler\HttpClient` with a `get()`
      returning body + status; options for `ignore_ssl`, `timeout`,
      `follow_redirects`, `headers`; and a `download()` binary seam.
      Type-hinted, PHPStan-clean (level 5).
- [x] `README.md` — list `Utils\Crawler\HttpClient` alongside
      `Utils\Crawler\CasperTrio` in the components line.

## Open items

- **Rate limiting** — the client deliberately does not enforce throttling; callers own that policy.
