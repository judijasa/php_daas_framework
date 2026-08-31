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
        bashPkg = pkgs.bash;
        mariadbPkg = pkgs.mariadb_118;
        phpLinter = pkgs.phpstan;
        pre-commit = pkgs.pre-commit;
      in
      {
        # DEVELOPMENT ENVIRONMENT ONLY: PHP + composer + local MariaDB, for
        # standalone/template usage. Framework code (src/, the CLIs, and the
        # dev scripts) is Composer-delivered (vendor/bin), not re-exported
        # here, so the flake keeps only the environment binaries (php runtime
        # + extensions, composer, mariadb, bash, phpstan, pre-commit). ema
        # (CLI + init-cluster.sh) is also Composer-delivered via the
        # `judijasa/ema` package, so it is absent from this shell.
        devShells.default = pkgs.mkShell {
          buildInputs = [
            bashPkg
            phpPkg
            phpComposer
            mariadbPkg
            phpLinter   # phpstan: scoped commit-time + full-repo push-time gates
            pre-commit  # pre-commit framework (hook shims installed by make dev-init)
          ];
          shellHook = ''
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
