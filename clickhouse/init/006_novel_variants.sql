-- 006: prompt_variant новеллы — справочник для аналитики.
--
-- В событиях llm.usage поля prompt_variant нет (его пришлось бы добавлять в
-- ai_plot_generator), поэтому вариант промптов берём из SQL-базы генератора:
-- таблица novels.prompt_variant там уже есть. Справочник наполняется командой
-- `make sync-variants` (id новеллы ↔ вариант) и обновляется повторным запуском.
--
-- Ключ справочника — entity_id из analytics.llm_calls (id новеллы строкой).
-- Если новеллы в справочнике нет (удалена, ещё не синхронизирована), дашборд
-- показывает её как `unknown` — это осознанный fallback, а не ошибка.
--
-- Файл идемпотентен: можно применять повторно на существующей базе.

-- ---------------------------------------------------------------------------
-- 1. Справочник «новелла → вариант промптов»
-- ---------------------------------------------------------------------------
-- ReplacingMergeTree по novel_id: повторная синхронизация перезаписывает
-- строку, а не плодит дубликаты. synced_at — версия строки.
CREATE TABLE IF NOT EXISTS analytics.novel_prompt_variants
(
    novel_id String,
    prompt_variant LowCardinality (String),
    synced_at DateTime DEFAULT now()
)
ENGINE = ReplacingMergeTree (synced_at)
ORDER BY novel_id;

-- ---------------------------------------------------------------------------
-- 2. Представление с дедупликацией
-- ---------------------------------------------------------------------------
-- Читаем справочник через argMax, а не через FINAL: merge у ReplacingMergeTree
-- может быть отложен, и без этого JOIN мог бы вернуть несколько строк.
CREATE OR REPLACE VIEW analytics.novel_prompt_variants_v AS
SELECT
    novel_id,
    argMax(prompt_variant, synced_at) AS prompt_variant
FROM analytics.novel_prompt_variants
GROUP BY novel_id;
