#!/usr/bin/env python3
"""Projeta as definições canônicas em ./ia/ para o que o Claude Code exige em ./.claude/:

- Agentes: ./ia/agents/*.md (multi-IA, com provider/model/fallback) → ./.claude/agents/*.md
  (Claude Code sempre roda no seu próprio modelo, então esses campos são descartados aqui —
  eles importam apenas quando o MESMO arquivo é lido pelo subot_orchestrator).
- Skills: ./ia/skills/*/SKILL.md → ./.claude/skills/*/SKILL.md (cópia direta, sem transformação
  — Claude Code só enxerga skills dentro de .claude/skills/).

Rode de novo depois de editar qualquer coisa em ./ia/agents/ ou ./ia/skills/.

Sem dependências externas de propósito (nem PyYAML) — precisa rodar em qualquer host só com
Python padrão, sem passo de 'pip install' antes. O parser abaixo cobre só o subconjunto de YAML
usado em ia/agents/*.md (linhas 'chave: valor' e listas '  - item'), não é um parser de YAML geral.
"""
from __future__ import annotations

import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent.parent
SRC = ROOT / "ia" / "agents"
DST = ROOT / ".claude" / "agents"
SKILLS_SRC = ROOT / "ia" / "skills"
SKILLS_DST = ROOT / ".claude" / "skills"


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
        f"<!-- gerado por bastiao/scripts/sync-claude-agents.py a partir de ia/agents/{path.name}; não edite "
        f"diretamente. Origem multi-IA: provider={fm.get('provider', '?')} model={fm.get('model', '?')} -->\n"
        f"Ferramentas MCP equivalentes: {mcp_tools}\n\n"
    )
    out_fm = f"name: {fm['name']}\ndescription: {fm['description']}\n"
    return f"---\n{out_fm}---\n\n{header}{body.strip()}\n"


def sync_skills() -> None:
    """Copia ia/skills/*/SKILL.md pra .claude/skills/*/SKILL.md sem transformação — Claude Code
    só enxerga skills dentro de .claude/, então esse espelho é 100% gerado, nunca editado à mão."""
    if not SKILLS_SRC.exists():
        return
    for skill_dir in sorted(p for p in SKILLS_SRC.iterdir() if p.is_dir()):
        src_file = skill_dir / "SKILL.md"
        if not src_file.exists():
            continue
        dst_dir = SKILLS_DST / skill_dir.name
        dst_dir.mkdir(parents=True, exist_ok=True)
        (dst_dir / "SKILL.md").write_text(src_file.read_text(encoding="utf-8"), encoding="utf-8")
        print(f"sincronizado skills/{skill_dir.name}/SKILL.md")


def main() -> int:
    if not SRC.exists():
        print(f"nenhum agente canônico encontrado em {SRC}", file=sys.stderr)
        return 1
    DST.mkdir(parents=True, exist_ok=True)
    for path in sorted(SRC.glob("*.md")):
        (DST / path.name).write_text(project(path), encoding="utf-8")
        print(f"sincronizado {path.name}")
    sync_skills()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
