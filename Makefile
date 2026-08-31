# php_daas_framework Makefile (dev-only; the framework CLIs phprun/deploy/
# gen-env/cron-manifest and the dev scripts init-local-env.sh and
# pf-shell-enter.sh are Composer-delivered to consumers via the `bin` array;
# init-cluster.sh is owned by ema and Composer-delivered via ema's package).

SHELL := $(shell which bash 2>/dev/null)

# Machine paths are derived from the repo root and owned by this Makefile
# (not by the environment): .env is a regenerated snapshot and nothing
# exports these into the shell anymore. The defaults let every target run
# standalone, e.g. `make dev-init` via ssh where no env vars exist.
REPO_PATH = $(CURDIR)
REPO_VAR = $(REPO_PATH)/var
REPO_LOG = $(REPO_VAR)/log
MYSQL_BASE_DIR = $(REPO_VAR)/mariadb
MYSQL_DATA_DIR = $(MYSQL_BASE_DIR)/data
MYSQL_UNIX_PORT = $(MYSQL_BASE_DIR)/mysql.sock
MYSQL_PID_FILE = $(MYSQL_BASE_DIR)/mysql.pid

_dev-init: DEV_VAR_DIR = $(REPO_VAR)
_dev-init: DEV_DB_DIR = $(MYSQL_BASE_DIR)
_dev-init: DEV_DB_DATA_DIR = $(MYSQL_DATA_DIR)
_dev-init: DEV_DB_UNIX_PORT = $(MYSQL_UNIX_PORT)
_dev-init: DEV_DB_PID_FILE = $(MYSQL_PID_FILE)
_dev-init: DEV_LOG_DIR = $(REPO_LOG)

.PHONY: help dev-init _dev-assert-nix _dev-init _dev-init-git-hooks _dev-create-dirs \
    _dev-init-composer _dev-init-cluster _dev-init-local-env

help:
	@echo "Available initialization targets:"
	@echo "  dev-init   - Run ONCE after cloning locally to build the dev sandbox"

dev-init: _dev-assert-nix _dev-init

_dev-assert-nix:
	@if [ -z "$$IN_NIX_SHELL" ]; then \
	    echo "ERROR: This target must be run inside 'nix develop'"; \
	    exit 1; \
	fi

_dev-init: _dev-init-git-hooks _dev-create-dirs _dev-init-composer _dev-init-cluster _dev-init-local-env
	@echo "Developer environment successfully initialized."

_dev-init-git-hooks:
	@bin/dev/init-git-hooks.sh

_dev-create-dirs:
	@echo "Creating local logging and storage directories..."
	mkdir -p $(DEV_LOG_DIR) $(DEV_DB_DATA_DIR)

_dev-init-composer:
	@echo "Removing vendor/ if exists..."
	-rm -rf vendor
	@echo "Running composer install...";
	composer install

_dev-init-cluster:
	@vendor/bin/init-cluster.sh "$(DEV_DB_DATA_DIR)" "$(DEV_DB_PID_FILE)" "$(DEV_DB_UNIX_PORT)"

_dev-init-local-env:
	@bin/dev/init-local-env.sh
