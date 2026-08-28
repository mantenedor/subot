#!/usr/bin/env python3
"""Projeta as definições canônicas e multi-IA em ./agents/*.md para agentes compatíveis com
Claude Code em ./.claude/agents/*.md. O Claude Code sempre roda um agente no seu próprio modelo,
então os campos provider/model/fallback são descartados aqui — eles importam apenas quando o
MESMO arquivo agents/*.md é lido pelo subot_orchestrator. Rode de novo depois de editar qualquer
coisa em ./agents/."""
from __future__ import annotations

import sys
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parent.parent
SRC = ROOT / "agents"
DST = ROOT / ".claude" / "agents"


def project(path: Path) -> str:
    text = path.read_text(encoding="utf-8")
    _, fm_raw, body = text.split("---", 2)
    fm = yaml.safe_load(fm_raw) or {}
    tools = fm.get("tools", [])
    mcp_tools = ", ".join(f"mcp__{t}__*" for t in tools)
    out_fm = {"name": fm["name"], "description": fm["description"]}
    header = (
        f"<!-- gerado por scripts/sync-claude-agents.py a partir de agents/{path.name}; não edite "
        f"diretamente. Origem multi-IA: provider={fm.get('provider')} model={fm.get('model')} -->\n"
        f"Ferramentas MCP equivalentes: {mcp_tools}\n\n"
    )
    return f"---\n{yaml.safe_dump(out_fm, sort_keys=False, allow_unicode=True)}---\n\n{header}{body.strip()}\n"


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
