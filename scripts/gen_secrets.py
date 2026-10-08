#!/usr/bin/env python3
"""Генерирует AIChat/Data/Secrets/Secrets.generated.swift с обфусцированным ключом.

Ключ берётся ТОЛЬКО из переменной окружения, чтобы он не попадал ни в чат
с агентом, ни в логи, ни в git открытым текстом:

    GROQ_API_KEY=gsk_... python3 scripts/gen_secrets.py

Схема: ключ XOR со случайной солью той же длины. В файле лежат два массива
байт; собирается строка только в рантайме. Это защита от grep и сканеров
секретов, а не от реверса — настоящая защита требует своего прокси-сервера.
"""
import os
import secrets
import sys
from pathlib import Path

key = os.environ.get("GROQ_API_KEY", "").strip()
if not key:
    sys.exit("Задайте переменную окружения GROQ_API_KEY")

raw = key.encode("utf-8")
salt = secrets.token_bytes(len(raw))
mixed = bytes(a ^ b for a, b in zip(raw, salt))


def swift_array(data: bytes) -> str:
    lines = []
    for i in range(0, len(data), 12):
        lines.append("        " + ", ".join(f"0x{b:02X}" for b in data[i:i + 12]))
    return "[\n" + ",\n".join(lines) + "\n    ]"


out = f"""// Сгенерировано scripts/gen_secrets.py — не редактировать вручную.
// Ключ обфусцирован (XOR с солью), открытым текстом в репозитории его нет.

enum Secrets {{
    private static let salt: [UInt8] = {swift_array(salt)}

    private static let mixed: [UInt8] = {swift_array(mixed)}

    static var groqAPIKey: String {{
        String(decoding: zip(mixed, salt).map {{ $0 ^ $1 }}, as: UTF8.self)
    }}
}}
"""

path = Path(__file__).resolve().parent.parent / "AIChat/Data/Secrets/Secrets.generated.swift"
path.parent.mkdir(parents=True, exist_ok=True)
path.write_text(out, encoding="utf-8")
print(f"OK: {path.relative_to(Path.cwd()) if path.is_relative_to(Path.cwd()) else path}")
