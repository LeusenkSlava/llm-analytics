# llm-analytics

Сервис аналитики расхода токенов LLM: сервисы-генераторы шлют события в Kafka,
ClickHouse их накапливает, Grafana показывает дашборды.

## Состав

- `clickhouse/init/001_llm_usage.sql` — базовые таблицы `llm_calls` (ReplacingMergeTree),
  очередь Kafka `llm_calls_queue` и материализованное представление `llm_calls_mv`.
- `clickhouse/init/002_cost_peak_offpeak.sql` — цены моделей, китайские праздники,
  курсы валют и представление `analytics.llm_calls_cost` со стоимостью вызова.
- `clickhouse/init/003_reasoning_and_scores.sql` — guard-колонка `reasoning_tokens`
  и удаление выпиленного скоринга сюжета (`novel_scores`).
- `clickhouse/init/004_schema_v2.sql` — одноразовая миграция на v2 (см. ниже).
- `clickhouse/init/005_prompts.sql` — колонка `messages` (полный промпт) + пересоздание MV.
- `grafana/dashboards/*.json` — дашборды (провижнятся из файлов автоматически).
- `scripts/report.py` — репортёр итогов/ответов (`make report`).
- `scripts/verify.py` — health-check полноты доставки (`make verify`).
- `docker-compose.yml` — ClickHouse + Grafana (за Traefik, `grafana.localhost`).

## Схема v2 (что изменилось)

- `llm_calls` — **ReplacingMergeTree** по `event_id`: один LLM-вызов = одна строка,
  повторная доставка (ретрай/outbox) не дублирует. Запросы к таблице идут через
  `FINAL` (или через представление `llm_calls_cost`, которое уже содержит `FINAL`).
- Новые колонки:
  - `event_id` — уникальный id вызова (дедуп);
  - `scene_order` — `0` для `create_novel`/настройки, `N` для сцены `scene_N`;
  - `response` — текст ответа LLM (roadmap/сцена/диалог), `''` для обычных вызовов.
  - `messages` — полный промпт (массив сообщений system/user/assistant) в виде
    JSON-строки, `''` если промпт не передан (добавлено в `005`).
- `TTL toDate(ts) + INTERVAL 90 DAY` — данные живут 90 дней (настраивается в `001`/`004`).
- Очередь Kafka читает с `input_format_skip_unknown_fields = 1` — старые события
  без новых полей не ломают парсинг.
- Скоринг сюжета (`novel_scores`, `novel_scores_composite`, дашборд «Сюжет») удалён.

## Дашборды

| Дашборд | uid | Назначение |
| ------- | --- | ---------- |
| LLM Overview | `llm-overview` | Здоровье: запросы/токены/cache/ошибки/латентность |
| LLM Cost / Обзор и итоги | `llm-cost` | Стоимость и юнит-экономика: итоги, цена за сцену/новеллу/шаг, разбивка input/cached/output, экономия кэша, доля reasoning |
| LLM Novels / drill-down | `llm-novels` | Разбор одной новеллы: цена за сцену, по операциям/шагам |
| LLM Scenes / Средняя цена сцены по новелам | `llm-scene-cost` | Цена одной сцены в токенах по всем новеллам: среднее/медиана, детали по сценам |
| LLM Trends | `llm-trends` | Средние по времени |

Число сцен новеллы считается как `max(scene_order)` (настройка `create_novel`
не смешивается со сценами — у неё `scene_order = 0`).

На дашборде `llm-scene-cost` цена сцены — это `prompt_tokens + completion_tokens`
по всем вызовам сцены (`scene_order > 0`), усреднённая по сценам новеллы.
Это линейный график: по X — номер новеллы (от первой к последней), по Y — средняя
цена одной сцены в токенах. Новеллы без сцен (только настройка/roadmap) на графике
не показываются: для них средняя цена сцены не определена.

## Запуск

```bash
make upd      # поднять стек
make down     # остановить
```

## Миграция на v2 (существующая база)

```bash
make ch-migrate
```

Команда идемпотентна. Она:

1. применяет `004_schema_v2.sql` — пересоздаёт `llm_calls` на ReplacingMergeTree
   (движок нельзя поменять через `ALTER`), **только если таблица ещё на старом движке**;
   повторные запуски этот шаг пропускают;
2. применяет `002` (цены/курсы/представление стоимости);
3. применяет `003` (guard-колонка `reasoning_tokens` + удаление скоринга);
4. применяет `005` (колонка `messages` для полного промпта + пересоздание MV).

> Пересоздание `llm_calls` дропает текущие данные намеренно: источник истины —
> `llm_logs/*.jsonl` (он полнее), история перезаливается разовым импортом
> `ai_plot_generator/scripts/migrate_logs.py` (задача B7 генератора).

Для свежей базы (`make up` на пустом томе) init-скрипты создают схему v2 сразу,
миграция не нужна.

## Репортёр

```bash
make report                        # итоги: токены/кэш/стоимость/ошибки по всем новеллам
make report ARGS="12"              # все запросы + токены + кэш + стоимость по новелле
make report ARGS="12 --responses"  # ответы LLM (roadmap/сцены/диалоги) → logs/responses/llm_responses_12.md
make report ARGS="12 --prompts"    # полные промпты + ответы → logs/prompts/llm_prompts_12.md
```

Прямой вызов: `python3 scripts/report.py [<novel_id>] [--responses|--prompts]`.

Отчёты-файлы складываются в папку `logs/`, разложенные по подпапкам:

```
logs/
├── prompts/       # --prompts   → llm_prompts_<novel_id>.md
└── responses/     # --responses → llm_responses_<novel_id>.md
```

Папки создаются автоматически, если их нет.

Колонки кэша (обе таблицы, источник — `prompt_tokens`/`cached_tokens` в `llm_calls`):

- `cached` — токены, попавшие в кэш (cache hit);
- `hit%` — попадание в кэш: `cached / prompt * 100`;
- `miss` — cache miss в токенах: `prompt − cached`;
- `save_rub` (только в итогах) — экономия кэша из `cache_savings_rub`.

В итогах вызовы с `entity_id = ''` сводятся в строку «—» и входят в ИТОГО
(поэтому `calls` в отчёте совпадает с числом строк в `llm_calls`).

В «фуле» по новелле (`report.py <novel_id>`) показывается размер промпта
(`length(messages)` в колонке `msg`) — для промптов, переданных в `messages`.

## Health-check полноты

```bash
make verify
```

Выводит `uniqExact(event_id)` в `llm_calls`, число событий, ожидающих в spool
(`llm_logs/outbox.jsonl`), и «расхождение» (pending → ещё не в CH). В штатном
режиме расхождение 0. От исторических файлов `llm_logs/*.jsonl` не зависит.

## Как считается стоимость

DeepSeek (модель `deepseek-flash` / DeepSeek-V4.1-Flash) тарифицирует вызовы
по двум тарифам — **peak** и **off-peak**, причём off-peak ровно вдвое дешевле:

| Токены (за 1M)   | peak, USD | off-peak, USD |
| ---------------- | --------- | ------------- |
| input, cache miss | 0.30     | 0.15          |
| input, cache hit  | 0.006    | 0.003         |
| output            | 1.20     | 0.60          |

**Peak** — по Пекину (UTC+8): будни 09:00–12:00 и 14:00–18:00, то есть
01:00–04:00 и 06:00–10:00 UTC, **кроме китайских государственных праздников**.
Всё остальное время, включая выходные и праздники, — off-peak.

Источник: <https://api-docs.deepseek.com/quick_start/pricing/>

Раньше в аналитике всегда применялся peak-тариф, поэтому стоимость новелл,
сгенерированных в непиковое время, завышалась примерно вдвое. Например,
новелла №20: было `0.0549 USD`, стало `0.02745 USD ≈ ¥0.18`, что совпадает
с platform.deepseek.com.

Вся логика собрана в представлении `analytics.llm_calls_cost`. Оно добавляет
к строке `llm_calls` колонки:

- `is_peak` — 1, если вызов попал в peak-окно;
- `cost_usd`, `cost_cny`, `cost_rub` — стоимость вызова;
- `cost_input_usd`, `cost_cached_usd`, `cost_output_usd` — разбивка по частям;
- `cache_savings_usd`, `cache_savings_cny`, `cache_savings_rub` — экономия кэша
  (сколько бы стоили cached-токены по цене cache-miss минус фактическая цена hit).

Дашборды обращаются к этому представлению, поэтому формула стоимости
не дублируется по панелям.

> Примечание про `is_peak`: проверка «не праздник» сделана явным подзапросом
> `toDate(ts) NOT IN (SELECT date FROM cn_holidays)`, а не через
> `LEFT JOIN … + h.date IS NULL`. При `join_use_nulls=0` (по умолчанию)
> непопавшая в JOIN дата получает default-значение `1970-01-01`, а не `NULL`,
> поэтому проверка `IS NULL` всегда ложна и пиковый тариф не применился бы никогда.

## Сцены и reasoning

- **Сцена** — колонка `scene_order` (`0` = настройка, `N` = сцена N). Первая сцена
  больше не прячется в `create_novel`: генераторы пишут `scene_1` и `scene_order = 1`.
  Число сцен новеллы = `max(scene_order)`.
- **`reasoning_tokens`** — колонка в `llm_calls` (проброшена из `llm_log`). Доля
  reasoning в output считается как `reasoning_tokens / completion_tokens`.

## Валюты

Стоимость считается в USD, а в CNY/RUB переводится по таблице
`analytics.currency_rates` (`per_usd` — сколько единиц валюты за 1 USD):

- `CNY = 6.67` — курс, зашитый в прайс DeepSeek (¥1 ↔ $0.15, ¥2 ↔ $0.30),
  поэтому сумма в юанях совпадает с platform.deepseek.com;
- `RUB = 84.97` — рыночный кросс-курс на 2026-10-09.

Обновить курсы:

```bash
make rates USD_CNY=6.67 USD_RUB=84.97
```

На каждом дашборде со стоимостью есть переменная **Валюта** (`RUB` / `CNY` / `USD`,
по умолчанию RUB) — она переключает все панели стоимости.

## Обслуживание

- **Новые модели / изменение цен** — правьте `002_cost_peak_offpeak.sql`
  (таблица `model_prices`) и применяйте `make ch-migrate`.
- **Праздники** — таблица `analytics.cn_holidays`; в `002` внесён официальный
  график на 2026 год. При наступлении нового года добавьте даты следующего года.
- **Фактическое имя модели** — генераторы пишут устаревший алиас
  `deepseek-v4-flash`; DeepSeek обслуживает его той же моделью по цене Flash,
  поэтому в `model_prices` есть обе записи.
- **TTL** — 90 дней задан в `001`/`004` (`TTL toDate(ts) + INTERVAL 90 DAY`).
