"""Log de auditoria append-only (JSONL, um arquivo por dia) — registra toda tentativa e execução,
independente de qual IA ou humano disparou a ação."""
from __future__ import annotations

import json
import os
import socket
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

AUDIT_DIR = Path(os.environ.get("SUBOT_AUDIT_DIR", "/opt/subot/data/audit"))


def _log_path(when: datetime | None = None) -> Path:
    when = when or datetime.now(timezone.utc)
    AUDIT_DIR.mkdir(parents=True, exist_ok=True)
    return AUDIT_DIR / f"{when:%Y-%m-%d}.jsonl"


def record(event: str, *, actor: str, risk: str, status: str, detail: dict[str, Any] | None = None) -> None:
    """Acrescenta uma entrada. Nunca levanta exceção por falha de I/O — em vez disso imprime em
    stderr, para que um disco de auditoria quebrado não trave silenciosamente uma operação nem
    permita que ela prossiga sem deixar rastro visível em algum lugar."""
    entry = {
        "ts": datetime.now(timezone.utc).isoformat(),
        "host": socket.gethostname(),
        "event": event,
        "actor": actor,
        "risk": risk,
        "status": status,
        "detail": detail or {},
    }
    line = json.dumps(entry, ensure_ascii=False)
    try:
        with _log_path().open("a", encoding="utf-8") as fh:
            fh.write(line + "\n")
    except OSError as exc:  # pragma: no cover - defensivo
        print(f"[subot-audit] FALHA ao gravar entrada de auditoria: {exc} :: {line}", flush=True)


def query(since: str | None = None, until: str | None = None, event: str | None = None, limit: int = 200) -> list[dict]:
    """Lê entradas correspondentes entre os arquivos diários, mais recentes primeiro."""
    if not AUDIT_DIR.exists():
        return []
    results: list[dict] = []
    for path in sorted(AUDIT_DIR.glob("*.jsonl"), reverse=True):
        for line in reversed(path.read_text(encoding="utf-8").splitlines()):
            try:
                entry = json.loads(line)
            except json.JSONDecodeError:
                continue
            if since and entry["ts"] < since:
                continue
            if until and entry["ts"] > until:
                continue
            if event and entry["event"] != event:
                continue
            results.append(entry)
            if len(results) >= limit:
                return results
    return results
