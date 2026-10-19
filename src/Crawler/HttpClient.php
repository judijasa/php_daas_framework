<?php

declare(strict_types=1);

namespace Utils\Crawler;

use CurlHandle;
use RuntimeException;

/**
 * Minimal cURL client for server-rendered pages.
 *
 * Rate limiting is deliberately left to callers: each call issues exactly one
 * request.
 */
class HttpClient
{
    private bool $ignoreSsl;
    private int $timeout;
    private bool $followRedirects;

    /** @var list<string> */
    private array $headers;

    /**
     * @param array{
     *     ignore_ssl?: bool,
     *     timeout?: int,
     *     follow_redirects?: bool,
     *     headers?: list<string>
     * } $options
     */
    public function __construct(array $options = [])
    {
        $this->ignoreSsl = $options['ignore_ssl'] ?? false;
        $this->timeout = $options['timeout'] ?? 30;
        $this->followRedirects = $options['follow_redirects'] ?? true;
        $this->headers = $options['headers'] ?? [];
    }

    /**
     * Fetches a URL and returns its body and HTTP status code.
     *
     * HTTP error statuses are returned, not thrown; callers decide whether a
     * response is acceptable. Transport failures throw.
     *
     * @return array{body: string, status: int}
     */
    public function get(string $url): array
    {
        $handle = $this->handle($url);
        curl_setopt($handle, CURLOPT_RETURNTRANSFER, true);

        $body = curl_exec($handle);
        $status = (int) curl_getinfo($handle, CURLINFO_HTTP_CODE);
        $error = curl_error($handle);
        curl_close($handle);

        if ($body === false) {
            throw new RuntimeException('HTTP request failed: ' . $error);
        }

        return ['body' => $body, 'status' => $status];
    }

    /**
     * Streams a URL's response body into $path, keeping binary payloads out of
     * memory.
     *
     * @return int HTTP status code.
     */
    public function download(string $url, string $path): int
    {
        $file = fopen($path, 'wb');

        if ($file === false) {
            throw new RuntimeException('Unable to open download destination: ' . $path);
        }

        $handle = $this->handle($url);
        curl_setopt($handle, CURLOPT_FILE, $file);

        $result = curl_exec($handle);
        $status = (int) curl_getinfo($handle, CURLINFO_HTTP_CODE);
        $error = curl_error($handle);
        curl_close($handle);
        fclose($file);

        if ($result === false) {
            throw new RuntimeException('HTTP download failed: ' . $error);
        }

        return $status;
    }

    private function handle(string $url): CurlHandle
    {
        $handle = curl_init($url);

        if ($handle === false) {
            throw new RuntimeException('Unable to initialize cURL');
        }

        curl_setopt($handle, CURLOPT_TIMEOUT, $this->timeout);
        curl_setopt($handle, CURLOPT_FOLLOWLOCATION, $this->followRedirects);

        if ($this->ignoreSsl) {
            curl_setopt($handle, CURLOPT_SSL_VERIFYPEER, false);
            curl_setopt($handle, CURLOPT_SSL_VERIFYHOST, 0);
        }

        if ($this->headers !== []) {
            curl_setopt($handle, CURLOPT_HTTPHEADER, $this->headers);
        }

        return $handle;
    }
}
