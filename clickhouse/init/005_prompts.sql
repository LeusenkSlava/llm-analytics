-- 005: колонка messages (полный промпт) в аналитике.
--
-- ai_plot_generator начинает слать в событии llm.usage поле `messages` —
-- весь промпт (массив сообщений system/user/assistant), сериализованный в
-- JSON-строку. Здесь добавляем под него колонку `messages String` и
-- пересоздаём MV, чтобы поле попадало в llm_calls (иначе колонка останется '').
--
-- Очередь Kafka НЕ поддерживает ALTER ADD COLUMN (storage Kafka), поэтому
-- очередь и MV пересоздаются. Смещения консьюмера хранятся в Kafka под
-- group `llm-analytics`, поэтому повторного чтения не будет (как в 004).
-- llm_calls_cost (002) перечисляет колонки явно и не включает
-- response/messages — представление стоимости менять не нужно.
-- input_format_skip_unknown_fields = 1 уже стоит в очереди: старые события
-- без поля messages не ломают парсинг (берётся default '').

-- ---------------------------------------------------------------------------
-- 1. Колонка messages в итоговой таблице (ReplacingMergeTree поддерживает ALTER).
-- ---------------------------------------------------------------------------
ALTER TABLE analytics.llm_calls
    ADD COLUMN IF NOT EXISTS messages String DEFAULT '' AFTER response;

-- ---------------------------------------------------------------------------
-- 2. Очередь Kafka пересоздаём с колонкой messages.
-- ---------------------------------------------------------------------------
DROP TABLE IF EXISTS analytics.llm_calls_mv;
DROP TABLE IF EXISTS analytics.llm_calls_queue;

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
    response String,
    messages String
) ENGINE = Kafka SETTINGS kafka_broker_list = 'kafka:9092',
kafka_topic_list = 'llm.usage',
kafka_group_name = 'llm-analytics',
kafka_format = 'JSONEachRow',
kafka_skip_broken_messages = 100,
input_format_skip_unknown_fields = 1;

-- ---------------------------------------------------------------------------
-- 3. MV пересоздаём: в его SELECT добавляем messages (иначе колонка останется '').
-- ---------------------------------------------------------------------------
CREATE MATERIALIZED VIEW analytics.llm_calls_mv TO analytics.llm_calls AS
SELECT
    parseDateTime64BestEffort(ts, 3) AS ts,
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
    response,
    messages
FROM analytics.llm_calls_queue;
