{
  description = "A PHP framework for data-as-a-service agent projects";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixpkgs-unstable";
    utils.url = "github:numtide/flake-utils";
    ema.url = "github:judijasa/ema";
  };

  outputs = { self, nixpkgs, utils, ema }:
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
        emaPkg = ema.packages.${system}.default;
      in
      {
        # PRODUCTION ARTIFACT: the phprun CLI + runner, for consumers of this
        # flake (e.g. added to a caller's commonPackages).
        packages.default = pkgs.runCommand "php-daas-framework" { } ''
          mkdir -p $out/bin
          cp ${./bin/phprun} $out/bin/phprun
          chmod +x $out/bin/phprun
          cp -r ${./src} $out/src
        '';

        # DEVELOPMENT ENVIRONMENT: PHP + composer + ema + local MariaDB, for
        # template usage and the quick DB integration test (see README).
        devShells.default = pkgs.mkShell {
          buildInputs = [
            pkgs.bash
            phpPkg
            phpComposer
            emaPkg
            pkgs.jq      # used by `ema init tables`
            pkgs.mariadb_118
          ];
          shellHook = ''
            export PHPRUN_REPO_PATH="$PWD"
            export PHPRUN_LOG_PATH="$PWD/var/log"
            export PHPRUN_REUTER_INI="$PWD/etc/reuter.ini"
            export EMA_TARGET="local"

            export MYSQL_BASE_DIR="$PWD/var/mariadb"
            export MYSQL_DATA_DIR="$MYSQL_BASE_DIR/data"
            export MYSQL_UNIX_PORT="$MYSQL_BASE_DIR/mysql.sock"
            export MYSQL_PID_FILE="$MYSQL_BASE_DIR/mysql.pid"

            mkdir -p "$PHPRUN_LOG_PATH"

            # Initialize the local MariaDB data directory once
            if [ ! -d "$MYSQL_DATA_DIR" ]; then
              echo "Initializing local MariaDB data directory..."
              mariadb-install-db --auth-root-authentication-method=normal \
                                 --datadir="$MYSQL_DATA_DIR" \
                                 --pid-file="$MYSQL_PID_FILE" > /dev/null 2>&1
            fi

            # Start the daemon if the data dir exists but no socket is up
            if [ -d "$MYSQL_DATA_DIR" ] && [ ! -S "$MYSQL_UNIX_PORT" ]; then
              echo "Starting isolated MariaDB server..."
              mysqld --datadir="$MYSQL_DATA_DIR" \
                     --pid-file="$MYSQL_PID_FILE" \
                     --socket="$MYSQL_UNIX_PORT" \
                     --skip-networking > /dev/null 2>&1 &
              MARIADB_PID=$!
              trap "echo 'Stopping local MariaDB server...'; kill $MARIADB_PID; wait $MARIADB_PID 2>/dev/null" EXIT
            fi

            # Customize the prompt (PS1)
            CYAN='\033[0;36m'
            GREEN='\033[0;32m'
            NC='\033[0m'
            export PS1="\[$CYAN\] \u@\h:\[$GREEN\]\w\[$NC\]\$ "
          '';
        };
      }
    );
}
