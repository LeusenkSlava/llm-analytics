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
# Применить миграции схемы к уже существующей базе (идемпотентно).
# 004 пересоздаёт llm_calls (движок → ReplacingMergeTree) — выполняется один раз,
# только если llm_calls ещё на старом движке. 002/003 безопасно гонять повторно.
ch-migrate:
	@engine="$$($(DOCKER_COMPOSE) exec -T clickhouse sh -c 'clickhouse-client --user "$$CLICKHOUSE_USER" --password "$$CLICKHOUSE_PASSWORD" --query "SELECT engine FROM system.tables WHERE database = '\''analytics'\'' AND name = '\''llm_calls'\''"')"; \
	if [ "$$engine" != "ReplacingMergeTree" ]; then \
		echo "→ миграция v2: пересоздаю llm_calls (ReplacingMergeTree)"; \
		$(DOCKER_COMPOSE) exec -T clickhouse sh -c 'clickhouse-client --user "$$CLICKHOUSE_USER" --password "$$CLICKHOUSE_PASSWORD" --multiquery' < clickhouse/init/004_schema_v2.sql; \
	else \
		echo "→ llm_calls уже ReplacingMergeTree — 004 пропущен"; \
	fi
	$(DOCKER_COMPOSE) exec -T clickhouse sh -c 'clickhouse-client --user "$$CLICKHOUSE_USER" --password "$$CLICKHOUSE_PASSWORD" --multiquery' < clickhouse/init/002_cost_peak_offpeak.sql
	$(DOCKER_COMPOSE) exec -T clickhouse sh -c 'clickhouse-client --user "$$CLICKHOUSE_USER" --password "$$CLICKHOUSE_PASSWORD" --multiquery' < clickhouse/init/003_reasoning_and_scores.sql

# Обновить курсы валют: make rates USD_CNY=7.1 USD_RUB=85.4
# (значение = сколько единиц валюты за 1 USD; для CNY удобно оставить 6.67,
#  чтобы сумма совпадала с platform.deepseek.com)
rates:
	@test -n "$(USD_CNY)" -a -n "$(USD_RUB)" || { echo "usage: make rates USD_CNY=6.67 USD_RUB=84.97"; exit 1; }
	printf "INSERT INTO analytics.currency_rates (code, per_usd) VALUES ('CNY', $(USD_CNY)), ('RUB', $(USD_RUB));" | \
		$(DOCKER_COMPOSE) exec -T clickhouse sh -c 'clickhouse-client --user "$$CLICKHOUSE_USER" --password "$$CLICKHOUSE_PASSWORD" --multiquery'
	@echo "rates updated: CNY=$(USD_CNY), RUB=$(USD_RUB) per USD"

# Репортёр: итоги по всем новеллам / по одной новелле / ответы LLM.
# Требует запущенный стек ClickHouse.
report:
	python3 scripts/report.py $(ARGS)

# Health-check полноты: uniqExact(event_id) в llm_calls ↔ события в spool (outbox).
# Выводит расхождение (или 0). Требует запущенный стек ClickHouse.
verify:
	python3 scripts/verify.py
