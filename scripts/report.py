#!/usr/bin/env python3
"""Репортёр аналитики LLM (llm-analytics v2).

Читает ClickHouse (через `docker compose exec clickhouse clickhouse-client`)
и печатает читаемые итоги. Три режима:

    report.py                        # итоги: токены/стоимость/ошибки по всем новеллам
    report.py <novel_id>             # «фул»: все запросы + токены + стоимость по новелле
    report.py <novel_id> --responses # roadmap/сцены/диалоги (JSON → .md)

Запуск:
    make report                      # режим «итоги»
    make report ARGS="12"            # по одной новелле
    make report ARGS="12 --responses"
    python3 scripts/report.py 12 --responses   # напрямую

Выходной код 0 — успех, 2 — ошибка запроса/ввода.
"""

import argparse
import json
import os
import subprocess
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
CH_USER = os.getenv("CH_USER", "analytics")
CH_PASSWORD = os.getenv("CH_PASSWORD", "password")


def ch_query(sql: str) -> str:
    """Выполняет SQL-запрос к ClickHouse и возвращает stdout (JSONEachRow)."""
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


def ch_query_rows(sql: str) -> list[dict]:
    """Выполняет запрос с FORMAT JSONEachRow и возвращает список строк-объектов."""
    if not sql.rstrip().endswith(";"):
        sql += ";"
    out = ch_query(sql)
    rows = []
    for line in out.splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            rows.append(json.loads(line))
        except json.JSONDecodeError:
            continue
    return rows


def _num(v, nd: int = 0) -> str:
    try:
        return f"{float(v):,.{nd}f}"
    except (TypeError, ValueError):
        return str(v)


# ---------------------------------------------------------------------------
# Режим 1: итоги по всем новеллам
# ---------------------------------------------------------------------------
def summary() -> None:
    rows = ch_query_rows(
        """
        SELECT
            entity_id,
            count() AS calls,
            sum(prompt_tokens) AS prompt_tokens,
            sum(completion_tokens) AS completion_tokens,
            sum(reasoning_tokens) AS reasoning_tokens,
            countIf(error != '') AS errors,
            round(sum(cost_usd), 6) AS cost_usd,
            round(sum(cost_rub), 4) AS cost_rub,
            max(scene_order) AS scenes
        FROM analytics.llm_calls_cost
        WHERE entity_id != ''
        GROUP BY entity_id
        ORDER BY toUInt64OrZero(entity_id)
        FORMAT JSONEachRow
        """
    )
    if not rows:
        print("Нет данных по новеллам.")
        return

    total_usd = sum(float(r["cost_usd"]) for r in rows)
    total_rub = sum(float(r["cost_rub"]) for r in rows)
    total_calls = sum(int(r["calls"]) for r in rows)
    total_errors = sum(int(r["errors"]) for r in rows)

    header = (
        f"{'novel':>6} {'calls':>6} {'scenes':>6} {'prompt':>9} {'compl':>9} "
        f"{'reason':>8} {'errors':>6} {'cost_usd':>10} {'cost_rub':>11}"
    )
    print("=== Итоги по новеллам ===")
    print(header)
    print("-" * len(header))
    for r in rows:
        print(
            f"{r['entity_id']:>6} {int(r['calls']):>6} {int(r['scenes']):>6} "
            f"{int(r['prompt_tokens']):>9} {int(r['completion_tokens']):>9} "
            f"{int(r['reasoning_tokens']):>8} {int(r['errors']):>6} "
            f"{_num(r['cost_usd'], 6):>10} {_num(r['cost_rub'], 2):>11}"
        )
    print("-" * len(header))
    print(
        f"{'ИТОГО':>6} {total_calls:>6} {'':>6} {'':>9} {'':>9} {'':>8} "
        f"{total_errors:>6} {_num(total_usd, 6):>10} {_num(total_rub, 2):>11}"
    )


# ---------------------------------------------------------------------------
# Режим 2: все запросы по одной новелле
# ---------------------------------------------------------------------------
def novel_full(novel_id: str) -> None:
    rows = ch_query_rows(
        f"""
        SELECT
            toString(ts) AS ts,
            scene_order,
            operation,
            step,
            model,
            prompt_tokens,
            completion_tokens,
            reasoning_tokens,
            cached_tokens,
            duration_ms,
            error,
            round(cost_usd, 6) AS cost_usd,
            round(cost_rub, 4) AS cost_rub
        FROM analytics.llm_calls_cost
        WHERE entity_id = '{novel_id}'
        ORDER BY scene_order, ts
        FORMAT JSONEachRow
        """
    )
    if not rows:
        print(f"Нет вызовов для новеллы {novel_id}.")
        return

    header = (
        f"{'ts':>19} {'sc':>3} {'op':>11} {'step':>22} {'prompt':>7} "
        f"{'compl':>7} {'reason':>7} {'cost_usd':>9} {'err':>3}"
    )
    print(f"=== Новелла {novel_id}: все вызовы ({len(rows)}) ===")
    print(header)
    print("-" * len(header))
    for r in rows:
        err = "!" if r.get("error") else ""
        print(
            f"{str(r['ts'])[:19]:>19} {int(r['scene_order']):>3} "
            f"{r['operation']:>11} {r['step']:>22} {int(r['prompt_tokens']):>7} "
            f"{int(r['completion_tokens']):>7} {int(r['reasoning_tokens']):>7} "
            f"{_num(r['cost_usd'], 6):>9} {err:>3}"
        )
    total = sum(float(r["cost_rub"]) for r in rows)
    print("-" * len(header))
    print(f"Итого стоимость (RUB): {_num(total, 2)}")


# ---------------------------------------------------------------------------
# Режим 3: ответы LLM (roadmap/сцены/диалоги) → .md
# ---------------------------------------------------------------------------
def _pretty_block(response: str) -> str:
    """Возвращает markdown-блок с pretty-print ответа (JSON или сырой текст)."""
    if not response:
        return ""
    try:
        obj = json.loads(response)
        return "```json\n" + json.dumps(obj, ensure_ascii=False, indent=2) + "\n```"
    except (json.JSONDecodeError, TypeError):
        return "```text\n" + response + "\n```"


def responses(novel_id: str) -> None:
    rows = ch_query_rows(
        f"""
        SELECT
            toString(ts) AS ts,
            scene_order,
            operation,
            step,
            response
        FROM analytics.llm_calls FINAL
        WHERE entity_id = '{novel_id}' AND response != ''
        ORDER BY scene_order, ts
        FORMAT JSONEachRow
        """
    )
    if not rows:
        print(f"Нет ответов (response != '') для новеллы {novel_id}.")
        return

    out_path = REPO_ROOT / f"llm_responses_{novel_id}.md"
    lines: list[str] = [
        f"# Ответы LLM — новелла {novel_id}",
        "",
        f"Всего записей с ответом: {len(rows)}",
        "",
    ]
    for r in rows:
        scene = int(r["scene_order"])
        lines += [
            f"## {r['operation']} · {r['step']}",
            "",
            f"_scene_order={scene} · ts: {r['ts']}_",
            "",
            _pretty_block(r.get("response") or ""),
            "",
        ]

    out_path.write_text("\n".join(lines).rstrip() + "\n", encoding="utf-8")
    print(f"Ответы записаны в {out_path}")


def main() -> int:
    parser = argparse.ArgumentParser(description="Репортёр аналитики LLM.")
    parser.add_argument("novel_id", nargs="?", default=None, help="id новеллы")
    parser.add_argument("--responses", action="store_true",
                        help="вывести ответы LLM (roadmap/сцены/диалоги) в .md")
    args = parser.parse_args()

    if args.responses:
        if not args.novel_id:
            print("Для --responses нужен <novel_id>:", file=sys.stderr)
            print("  report.py <novel_id> --responses", file=sys.stderr)
            return 2
        responses(args.novel_id)
    elif args.novel_id:
        novel_full(args.novel_id)
    else:
        summary()
    return 0


if __name__ == "__main__":
    sys.exit(main())
