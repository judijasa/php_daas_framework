<?php

declare(strict_types=1);

namespace Utils;

use Composer\Composer;
use Composer\EventDispatcher\EventSubscriberInterface;
use Composer\IO\IOInterface;
use Composer\Plugin\PluginInterface;
use Composer\Script\Event;
use Composer\Script\ScriptEvents;

/**
 * Composer plugin that bootstraps the crawler toolchain (CasperJS/PhantomJS)
 * on behalf of consumers of this framework.
 *
 * The phpcasperjs/casperjs/phantomjs packages cannot install their binaries
 * through their own composer scripts: those only execute from the root
 * package. This plugin performs the bootstrap automatically on every
 * install/update, so consumers never have to declare or wire any
 * crawler-specific dependency.
 *
 * When this repo is itself the root project (forkable template), its own
 * plugin does not self-activate, so composer.json references
 * `Utils\Plugin::installCrawlerToolchain` as a root script; composer invokes
 * it in-process with a real Event.
 */
final class Plugin implements PluginInterface, EventSubscriberInterface
{
    /**
     * Bitbucket no longer serves the official PhantomJS binaries (HTTP 402);
     * the installer falls back to this well-known GitHub mirror.
     */
    private const PHANTOMJS_CDN_MIRROR = 'https://github.com/Medium/phantomjs/releases/download/v2.1.1/';

    public function activate(Composer $composer, IOInterface $io): void
    {
    }

    public function deactivate(Composer $composer, IOInterface $io): void
    {
    }

    public function uninstall(Composer $composer, IOInterface $io): void
    {
    }

    /**
     * @return array<string, string>
     */
    public static function getSubscribedEvents(): array
    {
        return [
            ScriptEvents::POST_INSTALL_CMD => 'installCrawlerToolchain',
            ScriptEvents::POST_UPDATE_CMD => 'installCrawlerToolchain',
        ];
    }

    public static function installCrawlerToolchain(Event $event): void
    {
        self::installCasperJs($event);
        self::patchPhpcasperjs($event);
    }

    private static function installCasperJs(Event $event): void
    {
        $io = $event->getIO();

        if (!class_exists(\CasperJsInstaller\Installer::class)) {
            $io->write(
                '<warning>php-daas-framework: jerome-breton/casperjs-installer not found, skipping crawler bootstrap.</warning>'
            );
            return;
        }

        // Scoped workarounds for the installer's version probes and download
        // source; all are restored right after (consumers use the same tricks
        // at runtime, see their crawler helpers):
        // - OPENSSL_CONF: PhantomJS bundles an outdated OpenSSL that chokes
        //   on modern openssl.cnf files ("Auto configuration failed").
        // - PHANTOMJS_EXECUTABLE: the CasperJS probe runs the raw casperjs
        //   binary, which cannot locate phantomjs unless pointed at it.
        // - PHANTOMJS_CDNURL: Bitbucket no longer serves the official
        //   PhantomJS binaries (HTTP 402); fall back to a GitHub mirror,
        //   unless the consumer already configured their own source.
        $previousOpenSslConf = getenv('OPENSSL_CONF');
        $previousPhantomJsExecutable = getenv('PHANTOMJS_EXECUTABLE');
        $previousCdnUrl = $_ENV['PHANTOMJS_CDNURL'] ?? $_SERVER['PHANTOMJS_CDNURL'] ?? null;
        $consumerCdnUrl = $event->getComposer()->getPackage()->getExtra()['jakoch/phantomjs-installer']['cdnurl'] ?? null;
        $binDir = $event->getComposer()->getConfig()->get('bin-dir');
        putenv('OPENSSL_CONF=/dev/null');
        putenv('PHANTOMJS_EXECUTABLE=' . $binDir . '/phantomjs');
        if ($previousCdnUrl === null && $consumerCdnUrl === null) {
            $_ENV['PHANTOMJS_CDNURL'] = self::PHANTOMJS_CDN_MIRROR;
        }
        try {
            // Installs PhantomJS first, then CasperJS, into the root project's bin-dir.
            \CasperJsInstaller\Installer::install($event);
        } finally {
            if ($previousCdnUrl === null && $consumerCdnUrl === null) {
                unset($_ENV['PHANTOMJS_CDNURL']);
            }
            if ($previousOpenSslConf === false) {
                putenv('OPENSSL_CONF');
            } else {
                putenv('OPENSSL_CONF=' . $previousOpenSslConf);
            }
            if ($previousPhantomJsExecutable === false) {
                putenv('PHANTOMJS_EXECUTABLE');
            } else {
                putenv('PHANTOMJS_EXECUTABLE=' . $previousPhantomJsExecutable);
            }
        }
    }

    /**
     * phpcasperjs upstream bug: `private $script` prevents subclassing, which
     * Utils\Crawler\CasperTrio relies on (see src/Crawler/CasperTrio.php).
     */
    private static function patchPhpcasperjs(Event $event): void
    {
        $vendorDir = $event->getComposer()->getConfig()->get('vendor-dir');
        $target = $vendorDir . '/phpcasperjs/phpcasperjs/src/Casper.php';

        if (!is_file($target)) {
            return;
        }

        $content = (string) file_get_contents($target);
        $patched = str_replace(
            "private \$script = '';",
            "protected \$script = '';",
            $content
        );

        if ($patched !== $content) {
            file_put_contents($target, $patched);
            $event->getIO()->write('   - phpcasperjs: patched `private $script` to `protected $script`');
        }
    }
}
