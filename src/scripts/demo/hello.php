<?php

declare(strict_types=1);

require 'vendor/autoload.php';

use Utils\Agent;
use Utils\Logger;

/**
 * Minimal demo agent - run with:
 *   bin/phprun 'src/scripts/demo/hello.php:hello()'
 */
#[Agent(dbTarget: null)]
function hello(): void
{
    Logger::info('Hello from php_daas_framework!');
}
