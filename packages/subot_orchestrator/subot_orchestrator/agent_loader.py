"""Carrega definições canônicas de agente a partir de agents/*.md (front matter YAML + corpo
Markdown). Este é o formato fonte da verdade, multi-IA — tanto o subot_orchestrator quanto
scripts/sync-claude-agents.py (projeção para .claude/agents/) partem daqui."""
from __future__ import annotations

import os
from dataclasses import dataclass, field
from pathlib import Path

import yaml

AGENTS_DIR = Path(os.environ.get("SUBOT_AGENTS_DIR", "/opt/subot/agents"))


@dataclass
class AgentSpec:
    name: str
    description: str
    provider: str
    model: str
    tools: list[str] = field(default_factory=list)
    fallback: list[str] = field(default_factory=list)
    temperature: float = 0.2
    system_prompt: str = ""
    source_path: Path | None = None


def _split_front_matter(text: str) -> tuple[dict, str]:
    if not text.startswith("---"):
        raise ValueError("arquivo de agente sem front matter YAML (deve começar com '---')")
    _, fm_raw, body = text.split("---", 2)
    return yaml.safe_load(fm_raw) or {}, body.strip()


def load_agent(path: Path) -> AgentSpec:
    fm, body = _split_front_matter(path.read_text(encoding="utf-8"))
    required = {"name", "description", "provider", "model"}
    missing = required - fm.keys()
    if missing:
        raise ValueError(f"{path}: front matter do agente sem campos obrigatórios: {sorted(missing)}")
    return AgentSpec(
        name=fm["name"],
        description=fm["description"],
        provider=fm["provider"],
        model=str(fm["model"]),
        tools=list(fm.get("tools", [])),
        fallback=list(fm.get("fallback", [])),
        temperature=float(fm.get("temperature", 0.2)),
        system_prompt=body,
        source_path=path,
    )


def load_all(agents_dir: Path = AGENTS_DIR) -> dict[str, AgentSpec]:
    agents_dir = Path(agents_dir)
    specs: dict[str, AgentSpec] = {}
    if not agents_dir.exists():
        return specs
    for path in sorted(agents_dir.glob("*.md")):
        spec = load_agent(path)
        specs[spec.name] = spec
    return specs
