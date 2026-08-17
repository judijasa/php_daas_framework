<?php
// Guarantees correctly written CronJob/Agent attributes

declare(strict_types=1);

$files = array_slice($argv, 1);
$exitCode = 0;

foreach ($files as $file) {
    if (!file_exists($file)) continue;

    $tokens = token_get_all(file_get_contents($file));
    $n = count($tokens);
    $i = 0;
    $pendingAttrs = [];

    while ($i < $n) {
        $tok = $tokens[$i];

        if (is_array($tok) && in_array($tok[0], [T_WHITESPACE, T_COMMENT, T_DOC_COMMENT])) {
            $i++; continue;
        }

        if (is_array($tok) && $tok[0] === T_ATTRIBUTE) {
            $i++;
            $parenDepth = 0;
            $expectName = true;
            while ($i < $n) {
                $t = $tokens[$i];
                if ($t === '(')                                         { $parenDepth++; $i++; continue; }
                if ($t === ')')                                         { $parenDepth--; $i++; continue; }
                if ($t === ']' && $parenDepth === 0)                   { $i++; break; }
                if ($t === ',' && $parenDepth === 0)                   { $expectName = true; $i++; continue; }
                if (is_array($t) && $t[0] === T_WHITESPACE)            { $i++; continue; }
                if (is_array($t) && $t[0] === T_STRING && $expectName) { $pendingAttrs[] = $t[1]; $expectName = false; }
                $i++;
            }
            continue;
        }

        if (is_array($tok) && $tok[0] === T_FUNCTION) {
            $line = $tok[2];
            $j = $i + 1;
            while ($j < $n && is_array($tokens[$j]) && $tokens[$j][0] === T_WHITESPACE) $j++;
            $funcName = ($j < $n && is_array($tokens[$j]) && $tokens[$j][0] === T_STRING)
                ? $tokens[$j][1] : '(anonymous)';

            if (in_array('CronJob', $pendingAttrs) && !in_array('Agent', $pendingAttrs)) {
                fwrite(STDERR, "Error: {$file}:{$line}: '{$funcName}' has #[CronJob] but not #[Agent]\n");
                $exitCode = 1;
            }

            $pendingAttrs = [];
            $i = $j + 1;
            continue;
        }

        $pendingAttrs = [];
        $i++;
    }
}

exit($exitCode);

