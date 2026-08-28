#!/usr/bin/env python3
"""Servidor MCP para execução SSH e transferência de arquivos contra o inventário do subot,
sempre mediado pelo motor de política e confirmação do subot_core. Comandos sensíveis/destrutivos
retornam um confirm_token em vez de rodar; chame a mesma tool de novo com esse token para
executar de fato."""
from __future__ import annotations

from mcp.server.fastmcp import FastMCP
from subot_core import Inventory, SSHGateway

mcp = FastMCP("subot-ssh-connector")
gateway = SSHGateway()


def _format(result) -> str:
    if result.status == "confirmation_required":
        return (f"CONFIRMAÇÃO NECESSÁRIA ({result.reason}). Rode a mesma tool novamente com os "
                f"MESMOS argumentos mais confirm_token='{result.confirm_token}' para executar — "
                f"só faça isso depois de explicar o risco ao operador humano e obter aceite explícito.")
    if result.status == "blocked":
        return f"BLOQUEADO: {result.reason}"
    if result.status == "error":
        return f"ERRO: {result.reason}"
    return result.stdout or "ok"


@mcp.tool()
def list_hosts(group: str | None = None) -> str:
    """Lista hosts do inventário subot, opcionalmente filtrando por grupo."""
    hosts = Inventory().list(group=group)
    if not hosts:
        return "nenhum host encontrado" + (f" no grupo '{group}'" if group else "")
    return "\n".join(f"{h.name} ({h.user}@{h.address}:{h.port}) tags={h.tags}" for h in hosts)


@mcp.tool()
def ssh_exec(host: str, command: str, confirm_token: str | None = None) -> str:
    """Roda um comando de shell em um host gerenciado. Comandos safe rodam na hora. Comandos
    sensitive/destructive retornam status de confirmação necessária com um confirm_token — chame
    de novo com o MESMO host/command mais esse token para executar."""
    result = gateway.exec(host, command, actor="mcp:ssh_connector", confirm_token=confirm_token)
    if result.status == "executed":
        return f"exit_code={result.exit_code}\n--- stdout ---\n{result.stdout}\n--- stderr ---\n{result.stderr}"
    return _format(result)


@mcp.tool()
def ssh_upload(host: str, local_path: str, remote_path: str, confirm_token: str | None = None) -> str:
    """Envia um arquivo local para um host gerenciado via SFTP. Sempre exige confirmação."""
    result = gateway.upload(host, local_path, remote_path, actor="mcp:ssh_connector", confirm_token=confirm_token)
    return _format(result)


@mcp.tool()
def ssh_download(host: str, remote_path: str, local_path: str, confirm_token: str | None = None) -> str:
    """Baixa um arquivo de um host gerenciado via SFTP. Sempre exige confirmação."""
    result = gateway.download(host, remote_path, local_path, actor="mcp:ssh_connector", confirm_token=confirm_token)
    return _format(result)


if __name__ == "__main__":
    mcp.run()
