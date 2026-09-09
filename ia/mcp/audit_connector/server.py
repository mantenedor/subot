#!/usr/bin/env python3
"""Servidor MCP para consultas somente-leitura ao log de auditoria — permite que um agente
explique 'o que aconteceu' sem jamais poder alterar a trilha em si."""
from __future__ import annotations

import json

from mcp.server.fastmcp import FastMCP
from subot_core import audit

mcp = FastMCP("subot-audit-connector")


@mcp.tool()
def query_audit_log(since: str | None = None, until: str | None = None, event: str | None = None,
                     limit: int = 50) -> str:
    """Consulta o log de auditoria. `since`/`until` são timestamps ISO (ex: 2026-08-28T00:00:00).
    `event` filtra por tipo de evento (ex: 'ssh_exec', 'add_host'). Retorna as entradas mais
    recentes primeiro."""
    entries = audit.query(since=since, until=until, event=event, limit=limit)
    if not entries:
        return "nenhuma entrada de auditoria encontrada"
    return "\n".join(json.dumps(e, ensure_ascii=False) for e in entries)


if __name__ == "__main__":
    mcp.run()
