-- 1. Итоговая таблица с данными
CREATE TABLE analytics.llm_calls (
    ts DateTime64 (3, 'UTC'),
    service LowCardinality (String), -- какой генератор
    operation LowCardinality (String), -- create_novel, generate_scene...
    step LowCardinality (String), -- NovelGenerator, CodexResearcher...
    model LowCardinality (String),
    entity_id String, -- novel_id и т.п.
    job_id String,
    prompt_tokens UInt32,
    completion_tokens UInt32,
    cached_tokens UInt32,
    duration_ms UInt32,
    llm_requests UInt16,
    tool_calls UInt16,
    error String
) ENGINE = MergeTree
PARTITION BY
    toYYYYMM (ts)
ORDER BY (service, operation, step, ts);

-- 2. Таблица-читатель из Kafka
CREATE TABLE analytics.llm_calls_queue (
    ts String,
    service String,
    operation String,
    step String,
    model String,
    entity_id String,
    job_id String,
    prompt_tokens UInt32,
    completion_tokens UInt32,
    cached_tokens UInt32,
    duration_ms UInt32,
    llm_requests UInt16,
    tool_calls UInt16,
    error String
) ENGINE = Kafka SETTINGS kafka_broker_list = 'kafka:9092',
kafka_topic_list = 'llm.usage',
kafka_group_name = 'llm-analytics',
kafka_format = 'JSONEachRow',
kafka_skip_broken_messages = 100;

-- 3. Перекладывание из очереди в таблицу
CREATE MATERIALIZED VIEW analytics.llm_calls_mv TO analytics.llm_calls AS
SELECT
    parseDateTime64BestEffort (ts, 3) AS ts,
    *
EXCEPT
ts
FROM analytics.llm_calls_queue;

-- 4. Цены моделей, курсы валют и представление analytics.llm_calls_cost
--    создаются в 002_cost_peak_offpeak.sql (там же — учёт peak/off-peak).