#!/usr/bin/env python3
"""Health-check полноты аналитики (llm-analytics v2).

Сверяет счётчики доставки событий в ClickHouse:

  - uniqExact(event_id) в llm_calls — сколько уникальных вызовов дошло;
  - count() против uniqExact — «сырые» дубликаты до merge (информационно);
  - число событий в spool (outbox.jsonl) — события, ещё не ушедшие в CH.

«Расхождение» = число событий, ожидающих в outbox (не доставлены в CH).
В штатном режиме outbox пуст → расхождение 0.

Не зависит от исторических файлов llm_logs/*.jsonl (их больше нет):
читается только spool `outbox.jsonl`.

Запуск:
    make verify
    python3 scripts/verify.py

Выходной код 0 — расхождение 0, 1 — есть расхождение, 2 — ошибка.
"""

import os
import subprocess
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
CH_USER = os.getenv("CH_USER", "analytics")
CH_PASSWORD = os.getenv("CH_PASSWORD", "password")
OUTBOX = Path(os.getenv("OUTBOX_PATH", "../ai_plot_generator/llm_logs/outbox.jsonl"))
if not OUTBOX.is_absolute():
    OUTBOX = (REPO_ROOT / OUTBOX).resolve()


def ch_query(sql: str) -> str:
    proc = subprocess.run(
        [
            "docker", "compose", "exec", "-T", "clickhouse",
            "clickhouse-client",
            "--user", CH_USER,
            "--password", CH_PASSWORD,
            "--query", sql,
        ],
        capture_output=True, text=True, cwd=REPO_ROOT,
    )
    if proc.returncode != 0:
        print("Ошибка запроса к ClickHouse:", proc.stderr.strip(), file=sys.stderr)
        sys.exit(2)
    return proc.stdout


def llm_calls_counts() -> tuple[int, int]:
    """Возвращает (unique_event_ids, raw_rows) из analytics.llm_calls."""
    sql = (
        "SELECT uniqExact(event_id) AS unique_ids, count() AS raw_rows "
        "FROM analytics.llm_calls FORMAT TabSeparated"
    )
    out = ch_query(sql).strip()
    parts = out.split("\t")
    if len(parts) < 2:
        print("Неожиданный ответ ClickHouse:", out, file=sys.stderr)
        sys.exit(2)
    return int(parts[0]), int(parts[1])


def outbox_pending() -> int:
    """Число непустых строк в spool (outbox.jsonl). Нет файла → 0."""
    if not OUTBOX.exists():
        return 0
    try:
        lines = OUTBOX.read_text(encoding="utf-8").splitlines()
    except OSError as e:
        print(f"Не удалось прочитать spool {OUTBOX}: {e}", file=sys.stderr)
        sys.exit(2)
    return sum(1 for line in lines if line.strip())


def main() -> int:
    unique_ids, raw_rows = llm_calls_counts()
    pending = outbox_pending()
    dupes = raw_rows - unique_ids

    print("=== Health-check полноты (llm-analytics v2) ===")
    print(f"Событий в llm_calls (uniqExact event_id): {unique_ids}")
    print(f"Строк в llm_calls (до merge):              {raw_rows}")
    print(f"Дубликатов (raw - uniqExact):              {dupes}")
    print(f"Ожидающих в outbox (spool):                {pending}")
    print(f"Расхождение (pending → ещё не в CH):       {pending}")

    if pending == 0 and dupes == 0:
        print("\nРЕЗУЛЬТАТ: данные сходятся.")
        return 0
    print("\nРЕЗУЛЬТАТ: есть расхождение (см. выше).")
    return 1


if __name__ == "__main__":
    sys.exit(main())
