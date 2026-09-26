<?php

declare(strict_types=1);

// host_resolver — the one name<->IP lookup every host-taking CLI shares.
//
// A host has two spellings in this framework: the short name an operator types
// (`simo0`) and the ZeroTier IP that is the host's identity everywhere else
// (the etc/machines.ini [prod] key, the `ssh root@<host>` target, the
// pf-deploy.sh target). Two consumer-owned private files pair them:
//
//   etc/hosts        `ip name` lines — the same mapping gen-ssh-config turns
//                    into the dev ssh aliases. Optional private data: a
//                    consumer that keeps none loses the name spelling (and the
//                    name half of the pair), never the IP spelling.
//   etc/machines.ini [prod] roster, keyed by ZeroTier IP — the prod host list.
//                    Required: it is what makes a host a deploy target.
//
// resolve_host() accepts either spelling and returns the canonical host (the
// pair, with the IP half always known); it is the shared mechanism behind
// bin/pf-host (the CLI the bash CLIs call), bin/gen-firewall and bin/pf-roster.
// See doc/system/host-resolution.md.

// Parse an `ip name` mapping (the consumer's private etc/hosts) into name => ip.
//
// Blank lines, `#` comments and lines that are not `<ip> <name>` are skipped:
// the mapping is optional private data, and a line this lookup cannot read
// simply does not resolve (the requested spelling is then reported unknown).
// The first entry wins when a name is listed twice, like /etc/hosts.
//
// @return array<string,string>
function host_map(string $path): array
{
    if (!is_file($path)) {
        return [];
    }
    $lines = file($path, FILE_IGNORE_NEW_LINES | FILE_SKIP_EMPTY_LINES);
    if ($lines === false) {
        return [];
    }

    $map = [];
    foreach ($lines as $line) {
        $line = trim((string) preg_replace('/#.*$/', '', $line));
        if ($line === '') {
            continue;
        }
        $fields = preg_split('/\s+/', $line);
        if ($fields === false || count($fields) !== 2) {
            continue;
        }
        $ip = $fields[0];
        $name = $fields[1];
        if (!array_key_exists($name, $map)) {
            $map[$name] = $ip;
        }
    }

    return $map;
}

// The etc/machines.ini [prod] roster: ZeroTier IP => raw `tag[:name]` value. A
// missing file, a missing section and an unreadable file all read as an empty
// roster, so the caller decides what an empty roster means.
//
// @return array<string,string>
function prod_roster(string $path): array
{
    if (!is_file($path)) {
        return [];
    }
    $cnf = parse_ini_file($path, true, INI_SCANNER_RAW);
    if ($cnf === false || !isset($cnf['prod']) || !is_array($cnf['prod'])) {
        return [];
    }
    $out = [];
    foreach ($cnf['prod'] as $host => $value) {
        $host = (string) $host;
        // PHP's parse_ini_file skips `;` comments only; `#`-prefixed lines
        // (the templates' comment style) would parse as bogus keys - drop them.
        if ($host === '' || $host[0] === '#') {
            continue;
        }
        $out[$host] = is_string($value) ? trim($value) : '';
    }

    return $out;
}

// Split a comma-separated `tag[:name]` list into trimmed tokens, dropping
// empties (the roster grammar shared by every reader of [prod]).
//
// @return array<int,string>
function tokens(string $raw): array
{
    $out = [];
    foreach (explode(',', $raw) as $rawTok) {
        $tok = trim($rawTok);
        if ($tok !== '') {
            $out[] = $tok;
        }
    }

    return $out;
}

// Is this spelling an IPv4 address — the form the [prod] roster is keyed by?
function is_ipv4(string $spelling): bool
{
    return preg_match('/^\d{1,3}(?:\.\d{1,3}){3}$/', $spelling) === 1;
}

// Turn either spelling of a host into the canonical host: its short name and
// its ZeroTier IP, with [prod] membership enforced. The IP half is always set
// (the roster key, the ssh target); the name half is null when the consumer's
// etc/hosts maps no name to that IP.
//
// $error is set to the reason whenever null is returned (the caller owns the
// message: each CLI prefixes its own name).
//
// @param string|null $error
// @return array{name: ?string, ip: string}|null
function resolve_host(string $spelling, string $root, ?string &$error = null): ?array
{
    $error = null;
    $spelling = trim($spelling);
    if ($spelling === '') {
        $error = 'no host given';
        return null;
    }

    $roster = prod_roster($root . '/etc/machines.ini');
    if ($roster === []) {
        $error = "no [prod] roster in {$root}/etc/machines.ini (etc/machines.ini is consumer-owned private data — see doc/system/consumer-config.md)";
        return null;
    }

    $map = host_map($root . '/etc/hosts');

    if (is_ipv4($spelling)) {
        $ip = $spelling;
        $name = array_search($ip, $map, true);
        if ($name === false) {
            $name = null;
        }
    } else {
        $name = $spelling;
        if (!array_key_exists($name, $map)) {
            $error = "'{$spelling}' is not in {$root}/etc/hosts (the mapping that pairs a host's short name with its ZeroTier IP; it is consumer-owned private data — see doc/system/consumer-config.md)";
            return null;
        }
        $ip = $map[$name];
    }

    if (!array_key_exists($ip, $roster)) {
        $what = $name !== null && $name !== $spelling ? "{$name} ({$ip})" : $spelling;
        $error = "'{$what}' is not a [prod] host in {$root}/etc/machines.ini";
        return null;
    }

    return ['name' => $name, 'ip' => $ip];
}
