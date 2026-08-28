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
def open_desktop_session(
    host: str,
    ssh_username: str | None = None,
    ssh_password: str | None = None,
    ssh_command: str | None = None,
) -> str:
    """Garante que existe uma conexão Guacamole para o host do inventário informado (protocolo
    vem de hosts.yaml: 'rdp', 'vnc' ou 'ssh') e retorna a URL web para abri-la. Requer que um
    humano de fato clique no link e interaja com a sessão — esta tool não controla a sessão em
    si, só cria/reaproveita a conexão no Guacamole.

    Para host com protocolo 'ssh', informe ssh_username (obrigatório) e ssh_password (opcional —
    omita para autenticação sem senha/por chave já configurada do lado do servidor). ssh_command
    é opcional e substitui o shell padrão por um comando específico ao conectar — é assim que se
    configura o "console da IA": um host 'ssh' apontando para a própria VM, com ssh_command
    'docker exec -it subot-agent bash', faz o Guacamole cair direto dentro do container
    subot-agent (sem precisar rodar sshd dentro dele, o que exigiria root e contrariaria o
    hardening do container).

    Essas credenciais NÃO são salvas em hosts.yaml nem em nenhum arquivo do subot — são passadas
    direto ao Guacamole na criação da conexão; a partir daí é o próprio Guacamole (seu banco
    Postgres) quem guarda e usa. É um canal separado do 'ssh_connector' (que é o acesso SSH da
    própria IA, com a chave do bastião) — este aqui é acesso SSH gravado/auditado para um
    operador humano."""
    inv_host = Inventory().get(host)
    if inv_host.protocol not in ("rdp", "vnc", "ssh"):
        return f"host '{host}' está configurado com protocolo '{inv_host.protocol}', não rdp/vnc/ssh"

    existing = guac.list_connections()
    match = next((cid for cid, c in existing.items() if c.get("name") == host), None)
    if match is None:
        if inv_host.protocol == "ssh":
            if not ssh_username:
                return "protocolo 'ssh' exige o argumento 'ssh_username' (ssh_password/ssh_command são opcionais)"
            parameters = {"hostname": inv_host.address, "port": str(inv_host.port), "username": ssh_username}
            if ssh_password:
                parameters["password"] = ssh_password
            if ssh_command:
                parameters["command"] = ssh_command
        else:
            parameters = {"hostname": inv_host.address, "port": str(inv_host.port)}

        created = guac.create_connection(name=host, protocol=inv_host.protocol, parameters=parameters)
        match = created["identifier"]
        # nunca logar ssh_password — só metadados não sensíveis vão pro audit
        audit.record("guac_create_connection", actor="mcp:remote_desktop_connector", risk="sensitive",
                     status="executed", detail={"host": host, "connection_id": match, "protocol": inv_host.protocol,
                                                 "command": ssh_command})

    url = guac.connection_url(match)
    return f"Abra esta URL para iniciar a sessão {inv_host.protocol.upper()} com {host}: {url}"


if __name__ == "__main__":
    mcp.run()
