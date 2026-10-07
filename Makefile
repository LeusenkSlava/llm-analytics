# Shell / Make config
SHELL := bash
.SHELLFLAGS := -eu -o pipefail -c

.SILENT:
MAKEFLAGS += --no-print-directory

# -----------------------------
# User-configurable variables (edit this)
# INFRA_SERVICES: long-running infra (db, broker, cache, ...)
# INFRA_INIT_SERVICES: one-shot services that prepare INFRA_SERVICES
# MIGRATION_DB_SERVICE: transactional db service used by alembic (empty = no migrations)
# STAIRWAY_TEST: path to stairway test (empty = skip stairway step)
# -----------------------------
PROJECT_NAME ?= $(notdir $(abspath .))

# -----------------------------
# Internal vars / aliases
# -----------------------------
DOCKER_COMPOSE := docker compose -p $(PROJECT_NAME)

upd:
	$(DOCKER_COMPOSE) up -d --build --force-recreate

up:
	$(DOCKER_COMPOSE) up --build --force-recreate

just_up:
	$(DOCKER_COMPOSE) up -d

start:
	$(DOCKER_COMPOSE) start

restart:
	$(DOCKER_COMPOSE) restart

down:
	$(DOCKER_COMPOSE) down

stop:
	$(DOCKER_COMPOSE) stop
