<?php

declare(strict_types=1);

namespace Utils\Connectivity;

use PDO;

class Database extends PDO
{
    // Per-instance dev sandboxes live here, relative to the repo root (the
    // working directory the app layer runs from): one
    // var/sandbox/<name>-<GUID>/ directory per instance, the same layout the
    // `ema` CLI writes and resolves.
    private const SANDBOX_DIR = 'var/sandbox';

    private function __construct(string $dsn, string $user, string $pass, array $options = []) {
        parent::__construct($dsn, $user, $pass, $options);
    }

    private static function configPath(): string {
        // Production overrides the path explicitly (Apache SetEnv / nix-built phprun wrapper).
        $override = getenv('REUTER_INI');
        if ($override !== false && $override !== '') {
            return $override;
        }
        // CLI fallback: phprun runs from the consumer repo root, so the config
        // lives at $PWD/etc/reuter.ini.
        $cwdConfig = getcwd() . '/etc/reuter.ini';
        if (file_exists($cwdConfig)) {
            return $cwdConfig;
        }
        throw new \RuntimeException("reuter.ini not found. Set REUTER_INI or create etc/reuter.ini in the repo root.");
    }

    // Resolve the config file of a dev sandbox instance from the database name
    // alone (mirrors ema's _resolve_instance): exactly one
    // var/sandbox/<dbname>-*/reuter.ini must exist. Instances are named
    // <name>-<GUID>, so ambiguity is answered with the full form.
    public static function sandboxConfigPath(string $dbname): string {
        $matches = glob(getcwd() . '/' . self::SANDBOX_DIR . "/{$dbname}-*/reuter.ini") ?: [];
        if (count($matches) > 1) {
            throw new \RuntimeException("Multiple sandboxes match '$dbname' (use a full <name>-<GUID>).");
        }
        if ($matches === []) {
            throw new \RuntimeException(
                "No sandbox instance for '$dbname'. Run 'ema sandbox srv/<name>-<GUID>' first."
            );
        }
        return $matches[0];
    }

    private static function loadSection(string $path, string $dbname): array {
        $cnf = parse_ini_file($path, true);
        if ($cnf === false) {
            throw new \RuntimeException("Could not parse $path");
        }
        if (!isset($cnf[$dbname])) {
            throw new \RuntimeException("Target '$dbname' not found in $path");
        }
        return $cnf[$dbname];
    }

    private static function buildDsn(string $dbname, array $cnf): string {
        $server = $cnf['SERVER'];
        $port = $cnf['PORT'] ?? '3306';

        $dsn = "mysql:host={$server};port={$port};dbname={$dbname};charset=utf8mb4";

        $socket = getenv('MYSQL_UNIX_PORT');
        if ($socket !== false && $socket !== '') {
            $dsn .= ';unix_socket=' . $socket;
        }
        return $dsn;
    }

    private static function baseOptions(): array {
        return [
            PDO::ATTR_ERRMODE => PDO::ERRMODE_EXCEPTION,
            PDO::ATTR_DEFAULT_FETCH_MODE => PDO::FETCH_ASSOC,
            PDO::ATTR_EMULATE_PREPARES => false,
        ];
    }

    // The app layer's mode switch, shared with the ema CLI: `sandbox` is
    // explicit, while `prod` is the default (also for unset/empty, which is
    // how the app layer behaved before EMA_TARGET existed). Any other value is
    // an error rather than a silent fallback.
    private static function target(): string {
        $target = getenv('EMA_TARGET');
        if ($target === 'sandbox') {
            return 'sandbox';
        }
        if ($target === false || $target === '' || $target === 'prod') {
            return 'prod';
        }
        throw new \RuntimeException("EMA_TARGET must be 'sandbox' or 'prod' (got '{$target}').");
    }

    // Open a connection to $dbname, dispatching on EMA_TARGET:
    //   sandbox          -> connectSandbox (root over the instance socket)
    //   prod/unset/empty -> connectAs (service account, required)
    //
    // This is the app layer's single entry point. It is named connectTo, not
    // connect: PHP 8.4 added a static PDO::connect(), and this class extends
    // PDO, so a same-named method with these parameters is a fatal
    // incompatible-signature error.
    public static function connectTo(string $dbname, string $account = ''): self {
        return self::target() === 'sandbox'
            ? self::connectSandbox($dbname)
            : self::connectAs($dbname, $account);
    }

    // Open a connection for a service account (the prod path). The account
    // name is consumer policy — this framework does not know any specific
    // account. Its password is read from the <ACCOUNT>_PASSWORD key of the
    // [<dbname>] section (uppercased account name + `_PASSWORD`); an empty
    // value means a passwordless account.
    public static function connectAs(string $dbname, string $account): self {
        if ($account === '') {
            throw new \RuntimeException("Database account name must not be empty.");
        }
        $cnf = self::loadSection(self::configPath(), $dbname);
        $key = strtoupper($account) . '_PASSWORD';
        if (!array_key_exists($key, $cnf)) {
            throw new \RuntimeException(
                "Account '$account' has no '$key' key in section [$dbname]."
            );
        }
        // The prod path is TCP: when the consumer supplies an SSL dir, present
        // the machine's TLS client certificate (REQUIRE X509 membership). The
        // cert + key paths are derived from the single SSL_DIR value. Unset ->
        // plain TCP, exactly as before. The sandbox path never applies TLS (it
        // connects as root over the local unix socket), so these attributes are
        // added here in connectAs rather than in baseOptions().
        $options = self::baseOptions();
        $sslDir = getenv('SSL_DIR');
        if ($sslDir !== false && $sslDir !== '') {
            $options[PDO::MYSQL_ATTR_SSL_CERT] = $sslDir . '/client.crt';
            $options[PDO::MYSQL_ATTR_SSL_KEY] = $sslDir . '/client.key';
        }
        return new self(
            self::buildDsn($dbname, $cnf),
            $account,
            (string) $cnf[$key],
            $options
        );
    }

    // Open a connection to a local dev sandbox (the sandbox path): as root
    // over the instance's MYSQL_UNIX_PORT socket, with an empty password — the
    // sandbox is a user-owned local MariaDB, and ema applies DDL to it the
    // same way. The sandbox ini carries endpoint keys only (no
    // <ACCOUNT>_PASSWORD), so $account is prod-only and ignored here.
    public static function connectSandbox(string $dbname): self {
        $path = self::sandboxConfigPath($dbname);
        $cnf = self::loadSection($path, $dbname);
        $socket = $cnf['MYSQL_UNIX_PORT'] ?? '';
        if ($socket === '') {
            throw new \RuntimeException("Section [$dbname] in $path has no MYSQL_UNIX_PORT.");
        }
        return new self(
            "mysql:unix_socket={$socket};dbname={$dbname};charset=utf8mb4",
            'root',
            '',
            self::baseOptions()
        );
    }
}
