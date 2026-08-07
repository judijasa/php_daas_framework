<?php

declare(strict_types=1);

namespace Utils;

#[\Attribute]
class Agent
{
    public function __construct(public readonly ?string $dbTarget) {}
}
