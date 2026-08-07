<?php

declare(strict_types=1);

namespace Utils;

class Logger
{
    public static function info(string $message): void
    {
        echo '[' . date('Y-m-d H:i:s') . '] [INFO] ' . $message . PHP_EOL;
    }

    public static function debug(string $message): void
    {
        echo '[DEBUG] ' . $message . PHP_EOL;
    }
}
