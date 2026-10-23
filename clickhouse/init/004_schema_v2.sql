-- 004: миграция схемы на v2 (одноразовая).
--
-- llm_calls переводится с MergeTree на ReplacingMergeTree (ORDER BY event_id),
-- добавляются колонки event_id / scene_order / response, TTL 90 дней.
-- Движок нельзя поменять через ALTER, поэтому таблица пересоздаётся.
-- Старые данные намеренно не переносятся: источник истины — llm_logs/*.jsonl
-- (он полнее), историю перезаливает ai_plot_generator/scripts/migrate_logs.py.
--
-- Очередь Kafka и MV пересоздаются (смещения консьюмера хранятся в Kafka под
-- group `llm-analytics`, поэтому повторного чтения не будет).
--
-- Запуск: make ch-migrate (в Makefile обёрнут проверкой движка — выполняется
-- только когда llm_calls ещё на старом движке).

DROP TABLE IF EXISTS analytics.llm_calls_mv;
DROP TABLE IF EXISTS analytics.llm_calls_queue;
DROP TABLE IF EXISTS analytics.llm_calls;

CREATE TABLE analytics.llm_calls (
    ts DateTime64 (3, 'UTC'),
    event_id String,
    service LowCardinality (String),
    operation LowCardinality (String),
    step LowCardinality (String),
    model LowCardinality (String),
    entity_id String,
    job_id String,
    scene_order UInt16,
    prompt_tokens UInt32,
    completion_tokens UInt32,
    reasoning_tokens UInt32,
    cached_tokens UInt32,
    duration_ms UInt32,
    llm_requests UInt16,
    tool_calls UInt16,
    error String,
    response String
) ENGINE = ReplacingMergeTree
PARTITION BY
    toYYYYMM (ts)
ORDER BY event_id
TTL toDate (ts) + INTERVAL 90 DAY;

CREATE TABLE analytics.llm_calls_queue (
    event_id String,
    ts String,
    service String,
    operation String,
    step String,
    model String,
    entity_id String,
    job_id String,
    scene_order UInt16,
    prompt_tokens UInt32,
    completion_tokens UInt32,
    reasoning_tokens UInt32,
    cached_tokens UInt32,
    duration_ms UInt32,
    llm_requests UInt16,
    tool_calls UInt16,
    error String,
    response String
) ENGINE = Kafka SETTINGS kafka_broker_list = 'kafka:9092',
kafka_topic_list = 'llm.usage',
kafka_group_name = 'llm-analytics',
kafka_format = 'JSONEachRow',
kafka_skip_broken_messages = 100,
input_format_skip_unknown_fields = 1;

CREATE MATERIALIZED VIEW analytics.llm_calls_mv TO analytics.llm_calls AS
SELECT
    parseDateTime64BestEffort (ts, 3) AS ts,
    event_id,
    service,
    operation,
    step,
    model,
    entity_id,
    job_id,
    scene_order,
    prompt_tokens,
    completion_tokens,
    reasoning_tokens,
    cached_tokens,
    duration_ms,
    llm_requests,
    tool_calls,
    error,
    response
FROM analytics.llm_calls_queue;
