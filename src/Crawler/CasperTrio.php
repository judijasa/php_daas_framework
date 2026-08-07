<?php

namespace Utils\Crawler;

// Loaded via the consumer's composer autoloader, which provides phpcasperjs.
use Browser\Casper;

// Class extensions: https://www.w3schools.com/php/keyword_extends.asp

class CasperTrio extends Casper {
    public function __construct()
    {
        parent::__construct('vendor/bin/');
    }

    /**
     *  @param string $selector
     *  @param string $input
     *  @param boolean $reset
     */
    public function sendKeys($selector, $string, $reset=false)
        {
            $jsonData = json_encode($string);

            $fragment = <<<FRAGMENT
    casper.then(function () {
                this.sendKeys('$selector', $jsonData, { reset: $reset });
    });

    FRAGMENT;

            $this->script .= $fragment;

            return $this;
        }

    /**
     *  @param string $selector
     */
    public function fetchText($selector)
        {
            $fragment = <<<FRAGMENT
    casper.then(function () {
                this.echo(this.fetchText('$selector'));
    });

    FRAGMENT;

            $this->script .= $fragment;

            return $this;
        }
}
