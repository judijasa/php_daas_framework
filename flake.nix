{
  description = "A PHP framework for data-as-a-service agent projects";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixpkgs-unstable";
    utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, utils }:
    utils.lib.eachDefaultSystem (system:
      let
        pkgs = import nixpkgs { inherit system; };

        # The extension set mirrors composer.json's `ext-*` contract
        # (mysqli/pdo_mysql for the DB layer, bz2 for the
        # jakoch/phantomjs-installer composer side-effect): the flake makes
        # the extensions exist/loadable, and composer.json enforces them at
        # install (missing → hard failure).
        phpPkg = pkgs.php84.withExtensions ({ all, enabled }:
          enabled ++ [
            all.mysqli
            all.pdo_mysql
            all.bz2  # required by jakoch/phantomjs-installer (composer)
          ]
        );
        # Make sure Composer uses this php, as it has the required extensions.
        phpComposer = pkgs.php84Packages.composer.override {
          php = phpPkg;
        };
        # Dev-only analysis tooling for the pre-commit framework
        # (.pre-commit-config.yaml): phpstan powers the scoped commit-time and
        # full-repo push-time gates; pre-commit installs the pre-commit/pre-push
        # hook shims via `make dev-init` (bin/dev/init-git-hooks.sh).
        # readline: fixes arrow keys in nix shell on NixOS (without it, arrows produce escape sequences)
        # ncurses: together with readline, it fixes arrow keys in nix shell + tmux on NixOS
        bashPkg = pkgs.bashInteractive;  # Includes readline + ncurses
        jqPkg = pkgs.jq;      # the `ema` CLI (Composer-delivered) parses with jq
        tmuxPkg = pkgs.tmux;  # pf-shell-enter.sh aliases it; tmux-remote runs it on the host
        mariadbPkg = pkgs.mariadb_118;
        phpLinter = pkgs.phpstan;
        pre-commit = pkgs.pre-commit;

        # Common packages shared by dev and prod: the environment binaries
        # only. Framework + ema code (src/, the CLIs, the dev scripts) is
        # Composer-delivered to vendor/bin, so it is absent here — a flake
        # input would make this repo a second consumption point for the same
        # packages (see doc/system/composer.md).
        commonPackages = [
          bashPkg
          phpPkg
          phpComposer
          jqPkg
          tmuxPkg
        ];
      in
      {
        # PRODUCTION ARTIFACT (Built when running 'nix build')
        # The runtime the deployed repo executes in: `bin/deploy` builds it
        # locally, copies the closure to the host and symlinks it at
        # $DEPLOY_NIX_RESULT_DIR/result, so the host gets php (vendor/bin's
        # phprun/ema call it), composer (the remote `composer install`), jq
        # (ema), tmux (tmux-remote) and bash without building anything itself.
        # It DOES NOT spin up background services.
        packages.default = pkgs.symlinkJoin {
          name = "prod-dependencies";
          paths = commonPackages;
        };

        # DEVELOPMENT ENVIRONMENT (Triggered via 'nix develop')
        # The prod runtime plus the dev-only tooling (local MariaDB, phpstan,
        # pre-commit). `make dev-init` runs composer install to populate
        # vendor/bin with the framework + ema CLIs.
        devShells.default = pkgs.mkShell {
          buildInputs = commonPackages ++ [
            mariadbPkg
            phpLinter   # phpstan: scoped commit-time + full-repo push-time gates
            pre-commit  # pre-commit framework (hook shims installed by make dev-init)
          ];
          shellHook = ''
            # Set SHELL to bashInteractive so tmux uses bash with readline support
            export SHELL="${pkgs.bashInteractive}/bin/bash"

            . ./bin/dev/pf-shell-enter.sh php_daas

            # Customize the prompt (PS1)
            # Define ANSI color codes for readability
            CYAN='\033[0;36m'
            PURPLE='\033[0;35m'
            GREEN='\033[0;32m'
            NC='\033[0m' # No Color
            export PS1="\[$CYAN\] \u@\h:\[$GREEN\]\w\[$NC\]\$ "
          '';
        };
      }
    );
}
