<?php

declare(strict_types=1);

namespace Utils\Connectivity;

use PDO;

class Database extends PDO
{
    private function __construct(string $dsn, string $user, string $pass, array $options = []) {
        parent::__construct($dsn, $user, $pass, $options);
    }

    private static function configPath(): string {
        // Production overrides the path explicitly (Apache SetEnv / nix-built phprun wrapper).
        $override = getenv('PHPRUN_REUTER_INI');
        if ($override !== false && $override !== '') {
            return $override;
        }
        // CLI fallback: phprun runs from the consumer repo root, so the config
        // lives at $PWD/etc/reuter.ini.
        $cwdConfig = getcwd() . '/etc/reuter.ini';
        if (file_exists($cwdConfig)) {
            return $cwdConfig;
        }
        throw new \RuntimeException("reuter.ini not found. Set PHPRUN_REUTER_INI or create etc/reuter.ini in the repo root.");
    }

    private static function loadConfig(): array {
        $target = getenv('EMA_TARGET') ?: 'local';
        $path = self::configPath();
        $cnf = parse_ini_file($path, true);
        if ($cnf === false || !isset($cnf[$target])) {
            throw new \RuntimeException("Target '$target' not found in $path");
        }
        return $cnf[$target];
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

    public static function admin(string $dbname): self {
        $cnf = self::loadConfig();
        return new self(
            self::buildDsn($dbname, $cnf),
            'admin',
            $cnf['ADMIN_PASSWORD'],
            self::baseOptions()
        );
    }

    public static function reader(string $dbname): self {
        $cnf = self::loadConfig();
        return new self(
            self::buildDsn($dbname, $cnf),
            'reader',
            $cnf['READER_PASSWORD'],
            self::baseOptions()
        );
    }

    public static function public(string $dbname): self {
        $cnf = self::loadConfig();
        return new self(
            self::buildDsn($dbname, $cnf),
            'public',
            '',
            self::baseOptions()
        );
    }
}
