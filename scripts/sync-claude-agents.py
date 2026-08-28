#!/usr/bin/env python3
"""Projeta as definições canônicas e multi-IA em ./agents/*.md para agentes compatíveis com
Claude Code em ./.claude/agents/*.md. O Claude Code sempre roda um agente no seu próprio modelo,
então os campos provider/model/fallback são descartados aqui — eles importam apenas quando o
MESMO arquivo agents/*.md é lido pelo subot_orchestrator. Rode de novo depois de editar qualquer
coisa em ./agents/.

Sem dependências externas de propósito (nem PyYAML) — precisa rodar em qualquer host só com
Python padrão, sem passo de 'pip install' antes. O parser abaixo cobre só o subconjunto de YAML
usado em agents/*.md (linhas 'chave: valor' e listas '  - item'), não é um parser de YAML geral.
"""
from __future__ import annotations

import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SRC = ROOT / "agents"
DST = ROOT / ".claude" / "agents"


def parse_front_matter(fm_raw: str) -> dict[str, object]:
    data: dict[str, object] = {}
    current_key: str | None = None
    for line in fm_raw.splitlines():
        if not line.strip():
            continue
        stripped = line.strip()
        if stripped.startswith("- ") and current_key is not None:
            data.setdefault(current_key, [])
            value = data[current_key]
            if isinstance(value, list):
                value.append(stripped[2:].strip())
            continue
        if ":" in line:
            key, _, value = line.partition(":")
            key = key.strip()
            value = value.strip()
            current_key = key
            data[key] = [] if value == "" else value
    return data


def project(path: Path) -> str:
    text = path.read_text(encoding="utf-8")
    _, fm_raw, body = text.split("---", 2)
    fm = parse_front_matter(fm_raw)

    for required in ("name", "description"):
        if required not in fm:
            raise ValueError(f"{path}: front matter sem campo obrigatório '{required}'")

    tools = fm.get("tools", [])
    tools = tools if isinstance(tools, list) else []
    mcp_tools = ", ".join(f"mcp__{t}__*" for t in tools)

    header = (
        f"<!-- gerado por scripts/sync-claude-agents.py a partir de agents/{path.name}; não edite "
        f"diretamente. Origem multi-IA: provider={fm.get('provider', '?')} model={fm.get('model', '?')} -->\n"
        f"Ferramentas MCP equivalentes: {mcp_tools}\n\n"
    )
    out_fm = f"name: {fm['name']}\ndescription: {fm['description']}\n"
    return f"---\n{out_fm}---\n\n{header}{body.strip()}\n"


def main() -> int:
    if not SRC.exists():
        print(f"nenhum agente canônico encontrado em {SRC}", file=sys.stderr)
        return 1
    DST.mkdir(parents=True, exist_ok=True)
    for path in sorted(SRC.glob("*.md")):
        (DST / path.name).write_text(project(path), encoding="utf-8")
        print(f"sincronizado {path.name}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
