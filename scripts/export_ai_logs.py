#!/usr/bin/env python3
"""Экспортирует транскрипты Claude Code этого проекта в ai-logs/ с вычисткой
секретов и личных данных.

    python3 scripts/export_ai_logs.py            # все сессии проекта
    python3 scripts/export_ai_logs.py --check    # только проверить ai-logs/

Для каждой сессии пишет:
  ai-logs/<дата>_<id>.md     — читаемый лог: запросы, ответы, вызовы инструментов
  ai-logs/<дата>_<id>.jsonl  — те же сообщения в машинном виде

Что вычищается:
  - API-ключи (gsk_…, sk-…, Bearer …) → [REDACTED_KEY]
  - email → [email]
  - домашний путь и имя пользователя → ~ / user
  - картинки (скриншоты могут содержать чужие данные) → [image omitted]
  - блоки thinking, служебные вложения, снимки файлов

Скрипт НИЧЕГО из содержимого не печатает — только счётчики замен,
чтобы секрет не попал в терминал или в лог агента.
"""
import argparse
import json
import os
import re
import subprocess
import sys
from collections import Counter
from datetime import datetime
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
OUT = ROOT / "ai-logs"
HOME = os.path.expanduser("~")
USER = os.path.basename(HOME)
TOOL_RESULT_LIMIT = 3000

KEY_PATTERNS = [
    re.compile(r"gsk_[A-Za-z0-9]{10,}"),
    re.compile(r"sk-[A-Za-z0-9_\-]{20,}"),
    re.compile(r"(?i)bearer\s+[A-Za-z0-9._\-]{16,}"),
]
EMAIL = re.compile(r"[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}")


def transcripts_dir() -> Path:
    slug = re.sub(r"[^A-Za-z0-9]", "-", str(ROOT))
    return Path(HOME) / ".claude" / "projects" / slug


def git_email() -> str:
    try:
        return subprocess.run(["git", "config", "user.email"], cwd=ROOT,
                              capture_output=True, text=True).stdout.strip()
    except OSError:
        return ""


def make_redactor(stats: Counter):
    email = git_email()
    home_slug = re.sub(r"[^A-Za-z0-9]", "-", HOME)

    def redact(text: str) -> str:
        for pattern in KEY_PATTERNS:
            text, n = pattern.subn("[REDACTED_KEY]", text)
            stats["keys"] += n
        if email:
            n = text.count(email)
            text = text.replace(email, "[email]")
            stats["emails"] += n
        text, n = EMAIL.subn("[email]", text)
        stats["emails"] += n
        for needle, repl in ((HOME, "~"), (home_slug, "-~")):
            n = text.count(needle)
            text = text.replace(needle, repl)
            stats["paths"] += n
        text, n = re.subn(rf"\b{re.escape(USER)}\b", "user", text)
        stats["username"] += n
        return text

    return redact


def text_of(content) -> str:
    """Плоский текст из content результата инструмента."""
    if isinstance(content, str):
        return content
    parts = []
    for block in content or []:
        if isinstance(block, dict):
            if block.get("type") == "text":
                parts.append(block.get("text", ""))
            elif block.get("type") == "image":
                parts.append("[image omitted]")
    return "\n".join(parts)


def clean_blocks(content, stats: Counter):
    """Оставляет text / tool_use / tool_result, выкидывает thinking и картинки."""
    if isinstance(content, str):
        return [{"type": "text", "text": content}]
    blocks = []
    for block in content or []:
        if not isinstance(block, dict):
            continue
        kind = block.get("type")
        if kind == "text":
            blocks.append({"type": "text", "text": block.get("text", "")})
        elif kind == "image":
            stats["images"] += 1
            blocks.append({"type": "text", "text": "[image omitted]"})
        elif kind == "tool_use":
            blocks.append({"type": "tool_use", "name": block.get("name", ""),
                           "input": block.get("input", {})})
        elif kind == "tool_result":
            body = text_of(block.get("content"))
            if len(body) > TOOL_RESULT_LIMIT:
                body = body[:TOOL_RESULT_LIMIT] + "\n… [truncated]"
            blocks.append({"type": "tool_result", "text": body,
                           "is_error": bool(block.get("is_error"))})
    return blocks


def load_session(path: Path, stats: Counter):
    messages, title = [], None
    for line in path.open(encoding="utf-8"):
        try:
            record = json.loads(line)
        except json.JSONDecodeError:
            continue
        if record.get("type") == "custom-title":
            title = record.get("customTitle") or title
        if record.get("type") not in ("user", "assistant") or record.get("isMeta"):
            continue
        message = record.get("message") or {}
        blocks = clean_blocks(message.get("content"), stats)
        if blocks:
            messages.append({"role": record["type"], "timestamp": record.get("timestamp", ""),
                             "blocks": blocks})
    return title, messages


def short_input(name: str, data: dict) -> str:
    if name == "Bash":
        return data.get("description") or ""
    for key in ("file_path", "url", "query", "pattern"):
        if key in data:
            return str(data[key])
    return ""


def local_time(timestamp: str) -> str:
    try:
        return datetime.fromisoformat(timestamp.replace("Z", "+00:00")).astimezone().strftime("%H:%M:%S")
    except ValueError:
        return ""


def render_markdown(title, session_id, messages) -> str:
    out = [f"# {title or 'Claude Code session'}", "",
           f"Session `{session_id}`", ""]
    for m in messages:
        time = local_time(m["timestamp"])
        texts = [b for b in m["blocks"] if b["type"] == "text"]
        if m["role"] == "user" and texts:
            out += [f"## 👤 User · {time}", ""] + [b["text"] for b in texts] + [""]
        elif m["role"] == "assistant" and texts:
            out += [f"## 🤖 Claude · {time}", ""] + [b["text"] for b in texts] + [""]
        for b in m["blocks"]:
            if b["type"] == "tool_use":
                args = json.dumps(b["input"], ensure_ascii=False, indent=2)
                out += [f"<details><summary>🔧 {b['name']}: {short_input(b['name'], b['input'])}</summary>",
                        "", "```json", args, "```", "", "</details>", ""]
            elif b["type"] == "tool_result":
                label = "❌ result (error)" if b["is_error"] else "result"
                out += [f"<details><summary>{label}</summary>", "", "```", b["text"], "```",
                        "", "</details>", ""]
    return "\n".join(out)


def check(paths) -> int:
    """Ищет в готовых файлах то, чего там быть не должно. Печатает только имена файлов."""
    email = git_email()
    problems = 0
    for path in paths:
        text = path.read_text(encoding="utf-8")
        found = [name for name, hit in (
            ("key", any(p.search(text) for p in KEY_PATTERNS)),
            ("email", bool(email) and email in text),
            ("home path", HOME in text),
            ("username", re.search(rf"\b{re.escape(USER)}\b", text) is not None),
        ) if hit]
        if found:
            problems += 1
            print(f"✗ {path.relative_to(ROOT)}: {', '.join(found)}")
    print("✓ ai-logs чистые" if problems == 0 else f"Проблемных файлов: {problems}")
    return 1 if problems else 0


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--check", action="store_true", help="только проверить ai-logs/")
    args = parser.parse_args()

    if not args.check:
        source = transcripts_dir()
        sessions = sorted(source.glob("*.jsonl"))
        if not sessions:
            sys.exit(f"Транскрипты не найдены в {source}")
        OUT.mkdir(exist_ok=True)
        for path in sessions:
            stats = Counter()
            redact = make_redactor(stats)
            title, messages = load_session(path, stats)
            if not messages:
                continue
            day = messages[0]["timestamp"][:10] or datetime.now().strftime("%Y-%m-%d")
            stem = f"{day}_{path.stem[:8]}"
            md = redact(render_markdown(title, path.stem, messages))
            jsonl = "\n".join(redact(json.dumps(m, ensure_ascii=False)) for m in messages) + "\n"
            (OUT / f"{stem}.md").write_text(md, encoding="utf-8")
            (OUT / f"{stem}.jsonl").write_text(jsonl, encoding="utf-8")
            # Счётчики удвоены: md и jsonl вычищаются отдельно.
            print(f"{stem}: {len(messages)} messages, замены — "
                  + ", ".join(f"{k}={v}" for k, v in sorted(stats.items())))

    files = sorted(p for p in OUT.glob("*") if p.suffix in (".md", ".jsonl") and p.name != "README.md")
    return check(files)


if __name__ == "__main__":
    sys.exit(main())
