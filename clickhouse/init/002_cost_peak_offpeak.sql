-- 002: корректный расчёт стоимости LLM.
--
-- Что было не так: в 001 цена модели задавалась одним тарифом
-- (0.30 / 0.006 / 1.20 USD за 1M токенов) и применялась всегда.
-- На самом деле DeepSeek тарифицирует по двум тарифам — «высокому»
-- (peak) и «низкому» (off-peak), причём off-peak ровно вдвое дешевле.
-- Из-за этого новеллы, сгенерированные в непиковое время, в аналитике
-- выходили примерно в 2 раза дороже, чем в platform.deepseek.com.
--
-- Peak (по Пекину, UTC+8): будни 09:00–12:00 и 14:00–18:00,
-- т.е. 01:00–04:00 и 06:00–10:00 UTC, кроме китайских госпраздников.
-- Всё остальное время, включая выходные и праздники, — off-peak.
-- Источник: https://api-docs.deepseek.com/quick_start/pricing/
--
-- Дополнительно здесь появляются курсы валют (CNY, RUB), чтобы
-- стоимость можно было смотреть не только в USD.
--
-- Файл идемпотентен: его можно применять повторно на существующей базе.

-- ---------------------------------------------------------------------------
-- 1. Цены моделей: peak и off-peak (USD за 1M токенов)
-- ---------------------------------------------------------------------------
DROP TABLE IF EXISTS analytics.model_prices;
CREATE TABLE analytics.model_prices (
    model String,
    input_peak Float64, -- cache miss, peak
    cached_input_peak Float64, -- cache hit, peak
    output_peak Float64,
    input_offpeak Float64, -- cache miss, off-peak (= peak / 2)
    cached_input_offpeak Float64, -- cache hit, off-peak (= peak / 2)
    output_offpeak Float64
) ENGINE = ReplacingMergeTree
ORDER BY model;

-- deepseek-flash == DeepSeek-V4.1-Flash (актуальное имя модели).
-- deepseek-v4-flash — устаревший алиас: запросы по нему обслуживаются
-- той же моделью и тарифицируются так же, поэтому цена продублирована.
INSERT INTO analytics.model_prices
VALUES ('deepseek-flash', 0.30, 0.006, 1.20, 0.15, 0.003, 0.60),
    (
        'deepseek-v4-flash',
        0.30,
        0.006,
        1.20,
        0.15,
        0.003,
        0.60
    ),
    (
        'deepseek-v4-pro',
        1.32,
        0.044,
        3.96,
        0.66,
        0.022,
        1.98
    );

-- ---------------------------------------------------------------------------
-- 2. Китайские государственные праздники (в эти дни peak-окно не действует)
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS analytics.cn_holidays
(
    date Date,
    name String
)
ENGINE = MergeTree
ORDER BY date;

-- Официальный график на 2026 год:
-- https://www.gov.cn/zhengce/content/202511/content_7047090.htm
-- При наступлении нового года добавьте сюда даты следующего года.
INSERT INTO analytics.cn_holidays
SELECT toDate(t.1), t.2
FROM (
        SELECT arrayJoin(
                [
                    tuple('2026-01-01', 'Новый год'),
                    tuple('2026-01-02', 'Новый год'),
                    tuple('2026-01-03', 'Новый год'),
                    tuple('2026-02-15', 'Праздник весны (китайский Новый год)'),
                    tuple('2026-02-16', 'Праздник весны (китайский Новый год)'),
                    tuple('2026-02-17', 'Праздник весны (китайский Новый год)'),
                    tuple('2026-02-18', 'Праздник весны (китайский Новый год)'),
                    tuple('2026-02-19', 'Праздник весны (китайский Новый год)'),
                    tuple('2026-02-20', 'Праздник весны (китайский Новый год)'),
                    tuple('2026-02-21', 'Праздник весны (китайский Новый год)'),
                    tuple('2026-02-22', 'Праздник весны (китайский Новый год)'),
                    tuple('2026-02-23', 'Праздник весны (китайский Новый год)'),
                    tuple('2026-04-04', 'Цинмин'),
                    tuple('2026-04-05', 'Цинмин'),
                    tuple('2026-04-06', 'Цинмин'),
                    tuple('2026-05-01', 'День труда'),
                    tuple('2026-05-02', 'День труда'),
                    tuple('2026-05-03', 'День труда'),
                    tuple('2026-05-04', 'День труда'),
                    tuple('2026-05-05', 'День труда'),
                    tuple('2026-06-19', 'Праздник драконьих лодок'),
                    tuple('2026-06-20', 'Праздник драконьих лодок'),
                    tuple('2026-06-21', 'Праздник драконьих лодок'),
                    tuple('2026-09-25', 'Праздник середины осени'),
                    tuple('2026-09-26', 'Праздник середины осени'),
                    tuple('2026-09-27', 'Праздник середины осени'),
                    tuple('2026-10-01', 'День образования КНР'),
                    tuple('2026-10-02', 'День образования КНР'),
                    tuple('2026-10-03', 'День образования КНР'),
                    tuple('2026-10-04', 'День образования КНР'),
                    tuple('2026-10-05', 'День образования КНР'),
                    tuple('2026-10-06', 'День образования КНР'),
                    tuple('2026-10-07', 'День образования КНР')
                ]
            ) AS t
    )
WHERE (
        SELECT count()
        FROM analytics.cn_holidays
    ) = 0;

-- ---------------------------------------------------------------------------
-- 3. Курсы валют: сколько единиц валюты за 1 USD
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS analytics.currency_rates
(
    code LowCardinality (String),
    per_usd Float64,
    updated_at DateTime DEFAULT now()
)
ENGINE = ReplacingMergeTree (updated_at)
ORDER BY code;

-- CNY = 6.67 — курс, зашитый в прайс DeepSeek (¥1 ↔ $0.15, ¥2 ↔ $0.30),
-- именно поэтому итог в CNY совпадает с platform.deepseek.com.
-- RUB = 84.97 — рыночный кросс-курс (CNY/RUB ~12.74) на 2026-10-09.
-- Курсы можно менять: см. `make rates` в Makefile.
INSERT INTO analytics.currency_rates (code, per_usd)
SELECT t.1, t.2
FROM (
        SELECT arrayJoin(
                [tuple('CNY', 6.67), tuple('RUB', 84.97)]
            ) AS t
    )
WHERE (
        SELECT count()
        FROM analytics.currency_rates
    ) = 0;

-- ---------------------------------------------------------------------------
-- 4. Представление со стоимостью каждого вызова
-- ---------------------------------------------------------------------------
-- Колонки: is_peak, price_* (USD/1M), cost_usd, cost_cny, cost_rub,
-- а также cost_input_usd / cost_cached_usd / cost_output_usd для разбивки.
CREATE OR REPLACE VIEW analytics.llm_calls_cost AS
SELECT
    -- колонки llm_calls перечислены явно: при JOIN с model_prices
    -- ClickHouse иначе переименовывает model в `c.model`
    c.ts,
    c.service,
    c.operation,
    c.step,
    c.model AS model,
    c.entity_id,
    c.job_id,
    c.prompt_tokens,
    c.completion_tokens,
    c.cached_tokens,
    c.duration_ms,
    c.llm_requests,
    c.tool_calls,
    c.error,
    toUInt8(
        toDayOfWeek(c.ts) BETWEEN 1 AND 5
        AND (
            toHour(c.ts) BETWEEN 1 AND 3
            OR toHour(c.ts) BETWEEN 6 AND 9
        )
        AND h.date = toDate('1970-01-01')
    ) AS is_peak,
    if(is_peak, p.input_peak, p.input_offpeak) AS price_input,
    if(
        is_peak,
        p.cached_input_peak,
        p.cached_input_offpeak
    ) AS price_cached,
    if(is_peak, p.output_peak, p.output_offpeak) AS price_output,
    round(
        (c.prompt_tokens - c.cached_tokens) * price_input / 1e6,
        10
    ) AS cost_input_usd,
    round(c.cached_tokens * price_cached / 1e6, 10) AS cost_cached_usd,
    round(c.completion_tokens * price_output / 1e6, 10) AS cost_output_usd,
    round(
        cost_input_usd + cost_cached_usd + cost_output_usd,
        10
    ) AS cost_usd,
    round(cost_usd * rates.cny_per_usd, 10) AS cost_cny,
    round(cost_usd * rates.rub_per_usd, 10) AS cost_rub
FROM analytics.llm_calls AS c
LEFT JOIN analytics.model_prices AS p FINAL
    ON c.model = p.model
LEFT JOIN analytics.cn_holidays AS h
    ON toDate(c.ts) = h.date
CROSS JOIN (
    SELECT
        maxIf(per_usd, code = 'CNY') AS cny_per_usd,
        maxIf(per_usd, code = 'RUB') AS rub_per_usd
    FROM analytics.currency_rates FINAL
) AS rates;
