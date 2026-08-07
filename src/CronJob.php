<?php

declare(strict_types=1);

namespace Utils;

#[\Attribute]
class CronJob
{
    public function __construct(public readonly string $schedule) {}
}
