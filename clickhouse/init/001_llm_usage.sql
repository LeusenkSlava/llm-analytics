-- 001: базовая схема аналитики LLM (v2).
--
-- llm_calls — ReplacingMergeTree по event_id: один LLM-вызов = одна строка,
-- повторная доставка (ретрай/outbox) не дублирует данные. TTL — 90 дней.
-- Новые колонки v2: event_id, scene_order, response.
--
-- Таблицы очереди/MV перечисляют колонки явно (не `* EXCEPT ts`), чтобы
-- колонки не «расплывались» при изменении схемы.

-- 1. Итоговая таблица с данными
CREATE TABLE analytics.llm_calls (
    ts DateTime64 (3, 'UTC'),
    event_id String, -- уникальный id вызова (дедуп в ReplacingMergeTree)
    service LowCardinality (String), -- какой генератор
    operation LowCardinality (String), -- create_novel, scene_N
    step LowCardinality (String), -- NovelGenerator, SceneGenerator...
    model LowCardinality (String),
    entity_id String, -- novel_id и т.п.
    job_id String,
    scene_order UInt16, -- 0 = create_novel/настройка, N = сцена N
    prompt_tokens UInt32,
    completion_tokens UInt32,
    reasoning_tokens UInt32,
    cached_tokens UInt32,
    duration_ms UInt32,
    llm_requests UInt16,
    tool_calls UInt16,
    error String,
    response String -- текст ответа (roadmap/сцена/диалог), '' для обычных вызовов
) ENGINE = ReplacingMergeTree
PARTITION BY
    toYYYYMM (ts)
ORDER BY event_id
TTL toDate (ts) + INTERVAL 90 DAY;

-- 2. Таблица-читатель из Kafka.
--    input_format_skip_unknown_fields = 1: старые события (без event_id и пр.)
--    не ломают парсинг — неизвестные поля игнорируются, отсутствующие берут default.
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

-- 3. Перекладывание из очереди в таблицу (явный список колонок).
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

-- 4. Цены моделей, курсы валют и представление analytics.llm_calls_cost
--    создаются в 002_cost_peak_offpeak.sql (там же — учёт peak/off-peak).
