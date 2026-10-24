#!/usr/bin/env python3
"""Репортёр аналитики LLM (llm-analytics v2).

Читает ClickHouse (через `docker compose exec clickhouse clickhouse-client`)
и печатает читаемые итоги. Четыре режима:

    report.py                        # итоги: токены/кэш/стоимость/ошибки по всем новеллам
    report.py <novel_id>             # «фул»: все запросы + токены + кэш + стоимость по новелле
    report.py <novel_id> --responses # roadmap/сцены/диалоги (JSON → .md)
    report.py <novel_id> --prompts   # полные промпты (messages) + ответы → .md

Файлы-отчёты складываются в logs/:
    logs/prompts/llm_prompts_<novel_id>.md       (режим --prompts)
    logs/responses/llm_responses_<novel_id>.md   (режим --responses)
Папки создаются автоматически.

Запуск:
    make report                      # режим «итоги»
    make report ARGS="12"            # по одной новелле
    make report ARGS="12 --responses"
    make report ARGS="12 --prompts"
    python3 scripts/report.py 12 --prompts   # напрямую

Выходной код 0 — успех, 2 — ошибка запроса/ввода.
"""

import argparse
import json
import os
import subprocess
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
LOGS_DIR = REPO_ROOT / "logs"
PROMPTS_DIR = LOGS_DIR / "prompts"
RESPONSES_DIR = LOGS_DIR / "responses"
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
            sum(prompt_tokens) AS prompt_tokens_sum,
            sum(cached_tokens) AS cached_tokens_sum,
            sum(prompt_tokens - cached_tokens) AS miss_tokens,
            round(sum(cached_tokens) / greatest(sum(prompt_tokens), 1) * 100, 1)
                AS cache_hit_pct,
            sum(completion_tokens) AS completion_tokens_sum,
            sum(reasoning_tokens) AS reasoning_tokens_sum,
            countIf(error != '') AS errors,
            round(sum(cost_usd), 6) AS cost_usd,
            round(sum(cost_rub), 4) AS cost_rub,
            round(sum(cache_savings_rub), 4) AS cache_savings_rub,
            max(scene_order) AS scenes
        FROM analytics.llm_calls_cost
        GROUP BY entity_id
        ORDER BY entity_id = '', toUInt64OrZero(entity_id)
        FORMAT JSONEachRow
        """
    )
    if not rows:
        print("Нет данных.")
        return

    # Строки новелл и строка «без новеллы» (entity_id = ''), если она есть.
    novels = [r for r in rows if r["entity_id"] != ""]
    orphans = [r for r in rows if r["entity_id"] == ""]

    total_usd = sum(float(r["cost_usd"]) for r in rows)
    total_rub = sum(float(r["cost_rub"]) for r in rows)
    total_calls = sum(int(r["calls"]) for r in rows)
    total_errors = sum(int(r["errors"]) for r in rows)
    total_prompt = sum(int(r["prompt_tokens_sum"]) for r in rows)
    total_cached = sum(int(r["cached_tokens_sum"]) for r in rows)
    total_miss = sum(int(r["miss_tokens"]) for r in rows)
    total_hit = total_cached / max(total_prompt, 1) * 100
    total_savings = sum(float(r["cache_savings_rub"]) for r in rows)

    header = (
        f"{'novel':>6} {'calls':>6} {'scenes':>6} {'prompt':>9} {'cached':>9} "
        f"{'hit%':>6} {'miss':>9} {'compl':>9} {'reason':>8} {'errors':>6} "
        f"{'cost_usd':>10} {'cost_rub':>11} {'save_rub':>9}"
    )
    print("=== Итоги по новеллам ===")
    print(header)
    print("-" * len(header))

    def row(label: str, r: dict) -> str:
        return (
            f"{label:>6} {int(r['calls']):>6} {int(r['scenes']):>6} "
            f"{int(r['prompt_tokens_sum']):>9} {int(r['cached_tokens_sum']):>9} "
            f"{_num(r['cache_hit_pct'], 1):>6} {int(r['miss_tokens']):>9} "
            f"{int(r['completion_tokens_sum']):>9} {int(r['reasoning_tokens_sum']):>8} "
            f"{int(r['errors']):>6} {_num(r['cost_usd'], 6):>10} "
            f"{_num(r['cost_rub'], 2):>11} {_num(r['cache_savings_rub'], 2):>9}"
        )

    for r in novels:
        print(row(r["entity_id"], r))
    for r in orphans:
        print(row("—", r))
    print("-" * len(header))
    print(
        f"{'ИТОГО':>6} {total_calls:>6} {'':>6} {total_prompt:>9} {total_cached:>9} "
        f"{total_hit:>6.1f} {total_miss:>9} {'':>9} {'':>8} {total_errors:>6} "
        f"{_num(total_usd, 6):>10} {_num(total_rub, 2):>11} "
        f"{_num(total_savings, 2):>9}"
    )
    if orphans:
        print(
            "\n'—' — вызовы без новеллы (entity_id = '') включены в ИТОГО."
        )
    print("hit% = cached/prompt; miss = prompt − cached; "
          "save_rub — экономия кэша (сколько бы стоил cached по цене cache-miss).")


# ---------------------------------------------------------------------------
# Режим 2: все запросы по одной новелле
# ---------------------------------------------------------------------------
def novel_full(novel_id: str) -> None:
    rows = ch_query_rows(
        f"""
        SELECT
            toString(c.ts) AS ts,
            c.scene_order,
            c.operation,
            c.step,
            c.model,
            c.prompt_tokens,
            c.completion_tokens,
            c.reasoning_tokens,
            c.cached_tokens,
            c.duration_ms,
            c.error,
            round(c.cost_usd, 6) AS cost_usd,
            round(c.cost_rub, 4) AS cost_rub,
            length(m.messages) AS msg_len
        FROM analytics.llm_calls_cost AS c
        LEFT JOIN (
            SELECT event_id, messages
            FROM analytics.llm_calls FINAL
            WHERE entity_id = '{novel_id}'
        ) AS m ON c.event_id = m.event_id
        WHERE c.entity_id = '{novel_id}'
        ORDER BY c.scene_order, c.ts
        FORMAT JSONEachRow
        """
    )
    if not rows:
        print(f"Нет вызовов для новеллы {novel_id}.")
        return

    header = (
        f"{'ts':>19} {'sc':>3} {'op':>11} {'step':>22} {'prompt':>7} "
        f"{'cached':>7} {'hit%':>6} {'miss':>7} {'compl':>7} {'reason':>7} "
        f"{'cost_usd':>9} {'msg':>6} {'err':>3}"
    )
    print(f"=== Новелла {novel_id}: все вызовы ({len(rows)}) ===")
    print(header)
    print("-" * len(header))
    for r in rows:
        err = "!" if r.get("error") else ""
        prompt = int(r["prompt_tokens"])
        cached = int(r["cached_tokens"])
        hit = cached / prompt * 100 if prompt else 0.0
        print(
            f"{str(r['ts'])[:19]:>19} {int(r['scene_order']):>3} "
            f"{r['operation']:>11} {r['step']:>22} {prompt:>7} "
            f"{cached:>7} {hit:>6.1f} {prompt - cached:>7} "
            f"{int(r['completion_tokens']):>7} {int(r['reasoning_tokens']):>7} "
            f"{_num(r['cost_usd'], 6):>9} {int(r['msg_len'] or 0):>6} {err:>3}"
        )
    total = sum(float(r["cost_rub"]) for r in rows)
    tot_prompt = sum(int(r["prompt_tokens"]) for r in rows)
    tot_cached = sum(int(r["cached_tokens"]) for r in rows)
    tot_hit = tot_cached / tot_prompt * 100 if tot_prompt else 0.0
    print("-" * len(header))
    print(
        f"Итого стоимость (RUB): {_num(total, 2)} · "
        f"кэш: {tot_cached} / {tot_prompt} = {tot_hit:.1f}% hit, "
        f"miss {tot_prompt - tot_cached}"
    )


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


def _write_report(out_dir: Path, filename: str, lines: list[str], label: str) -> None:
    """Пишет отчёт в out_dir, создавая папку при необходимости."""
    out_dir.mkdir(parents=True, exist_ok=True)
    out_path = out_dir / filename
    out_path.write_text("\n".join(lines).rstrip() + "\n", encoding="utf-8")
    print(f"{label} записаны в {out_path}")


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

    _write_report(RESPONSES_DIR, f"llm_responses_{novel_id}.md", lines, "Ответы")


# ---------------------------------------------------------------------------
# Режим 4: полные промпты (messages) + ответы → .md
# ---------------------------------------------------------------------------
def prompts(novel_id: str) -> None:
    rows = ch_query_rows(
        f"""
        SELECT
            toString(ts) AS ts,
            scene_order,
            operation,
            step,
            messages,
            response
        FROM analytics.llm_calls FINAL
        WHERE entity_id = '{novel_id}' AND messages != ''
        ORDER BY scene_order, ts
        FORMAT JSONEachRow
        """
    )
    if not rows:
        print(f"Нет промптов (messages != '') для новеллы {novel_id}.")
        return

    lines: list[str] = [
        f"# Промпты и ответы LLM — новелла {novel_id}",
        "",
        f"Всего записей с промптом: {len(rows)}",
        "",
    ]
    for r in rows:
        scene = int(r["scene_order"])
        lines += [
            f"## {r['operation']} · {r['step']}",
            "",
            f"_scene_order={scene} · ts: {r['ts']}_",
            "",
            "### Промпт (messages)",
            "",
            _pretty_block(r.get("messages") or ""),
            "",
            "### Ответ (response)",
            "",
            _pretty_block(r.get("response") or ""),
            "",
        ]

    _write_report(PROMPTS_DIR, f"llm_prompts_{novel_id}.md", lines, "Промпты и ответы")


def main() -> int:
    parser = argparse.ArgumentParser(description="Репортёр аналитики LLM.")
    parser.add_argument("novel_id", nargs="?", default=None, help="id новеллы")
    parser.add_argument("--responses", action="store_true",
                        help="вывести ответы LLM (roadmap/сцены/диалоги) в .md")
    parser.add_argument("--prompts", action="store_true",
                        help="вывести полные промпты (messages) + ответы в .md")
    args = parser.parse_args()

    if args.responses:
        if not args.novel_id:
            print("Для --responses нужен <novel_id>:", file=sys.stderr)
            print("  report.py <novel_id> --responses", file=sys.stderr)
            return 2
        responses(args.novel_id)
    elif args.prompts:
        if not args.novel_id:
            print("Для --prompts нужен <novel_id>:", file=sys.stderr)
            print("  report.py <novel_id> --prompts", file=sys.stderr)
            return 2
        prompts(args.novel_id)
    elif args.novel_id:
        novel_full(args.novel_id)
    else:
        summary()
    return 0


if __name__ == "__main__":
    sys.exit(main())
