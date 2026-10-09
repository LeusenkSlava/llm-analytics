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

# -----------------------------
# ClickHouse
# -----------------------------
# Применить миграцию цен/валют к уже существующей базе (идемпотентно).
ch-migrate:
	$(DOCKER_COMPOSE) exec -T clickhouse sh -c 'clickhouse-client --user "$$CLICKHOUSE_USER" --password "$$CLICKHOUSE_PASSWORD" --multiquery' < clickhouse/init/002_cost_peak_offpeak.sql

# Обновить курсы валют: make rates USD_CNY=7.1 USD_RUB=85.4
# (значение = сколько единиц валюты за 1 USD; для CNY удобно оставить 6.67,
#  чтобы сумма совпадала с platform.deepseek.com)
rates:
	@test -n "$(USD_CNY)" -a -n "$(USD_RUB)" || { echo "usage: make rates USD_CNY=6.67 USD_RUB=84.97"; exit 1; }
	printf "INSERT INTO analytics.currency_rates (code, per_usd) VALUES ('CNY', $(USD_CNY)), ('RUB', $(USD_RUB));" | \
		$(DOCKER_COMPOSE) exec -T clickhouse sh -c 'clickhouse-client --user "$$CLICKHOUSE_USER" --password "$$CLICKHOUSE_PASSWORD" --multiquery'
	@echo "rates updated: CNY=$(USD_CNY), RUB=$(USD_RUB) per USD"
