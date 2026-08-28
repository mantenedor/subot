#!/usr/bin/env python3
"""Servidor MCP para abrir sessões RDP/VNC através do gateway Guacamole: cria/reaproveita uma
conexão para um host e retorna a URL web para o operador abrir — a IA nunca toca diretamente em
credenciais RDP/VNC nem nos pixels da sessão, apenas orquestra o gateway."""
from __future__ import annotations

from subot_core import GuacamoleClient, Inventory, audit
from mcp.server.fastmcp import FastMCP

mcp = FastMCP("subot-remote-desktop-connector")
guac = GuacamoleClient()


@mcp.tool()
def list_active_sessions() -> str:
    """Lista as conexões Guacamole (RDP/VNC/SSH) já configuradas no bastião."""
    data = guac.list_connections()
    if not data:
        return "nenhuma conexão configurada no Guacamole ainda"
    return "\n".join(f"{c.get('name')} ({c.get('protocol')}) id={cid}" for cid, c in data.items())


@mcp.tool()
def open_desktop_session(host: str) -> str:
    """Garante que existe uma conexão Guacamole para o host do inventário informado (protocolo
    vem de hosts.yaml, deve ser 'rdp' ou 'vnc') e retorna a URL web para abri-la. Requer que um
    humano de fato clique no link e interaja com a área de trabalho — esta tool não controla a
    sessão em si."""
    inv_host = Inventory().get(host)
    if inv_host.protocol not in ("rdp", "vnc"):
        return f"host '{host}' está configurado com protocolo '{inv_host.protocol}', não rdp/vnc"

    existing = guac.list_connections()
    match = next((cid for cid, c in existing.items() if c.get("name") == host), None)
    if match is None:
        created = guac.create_connection(
            name=host,
            protocol=inv_host.protocol,
            parameters={"hostname": inv_host.address, "port": str(inv_host.port)},
        )
        match = created["identifier"]
        audit.record("guac_create_connection", actor="mcp:remote_desktop_connector", risk="sensitive",
                     status="executed", detail={"host": host, "connection_id": match})

    url = guac.connection_url(match)
    return f"Abra esta URL para iniciar a sessão {inv_host.protocol.upper()} com {host}: {url}"


if __name__ == "__main__":
    mcp.run()
