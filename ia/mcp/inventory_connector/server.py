#!/usr/bin/env python3
"""Servidor MCP para ler e alterar com segurança o inventário de hosts (domain/.../host.yaml).
Leituras são livres; qualquer escrita (adicionar/editar um host) exige confirmação explícita, já
que o inventário controla o que os conectores SSH/RDP sequer têm permissão de alcançar."""
from __future__ import annotations

from mcp.server.fastmcp import FastMCP
from subot_core import Inventory, audit
from subot_core.confirm import ConfirmationStore

mcp = FastMCP("subot-inventory-connector")
confirmations = ConfirmationStore()


@mcp.tool()
def list_hosts(group: str | None = None) -> str:
    """Lista todos os hosts do inventário, opcionalmente filtrando por grupo."""
    hosts = Inventory().list(group=group)
    if not hosts:
        return "nenhum host encontrado"
    return "\n".join(
        f"{h.name}: {h.user}@{h.address}:{h.port} protocol={h.protocol} groups={h.groups} tags={h.tags}"
        for h in hosts
    )


@mcp.tool()
def add_host(name: str, domain_path: str, address: str, user: str = "root", port: int = 22,
             protocol: str = "ssh", groups: str = "", tags: str = "",
             confirm_token: str | None = None) -> str:
    """Adiciona (ou substitui) um host no inventário, em domain/<domain_path>/<name>/host.yaml.
    domain_path é a cadeia domínio/região/zona/pod/cluster separada por '/' (ex.: 'on-prem', ou
    'acme/us-east/zone-a'), sem incluir o nome do host — para um host já existente, o valor é
    ignorado (o host mantém seu diretório atual). Sempre exige confirmação: chame uma vez para
    receber um confirm_token, depois chame de novo com os MESMOS argumentos mais esse token."""
    payload = {"name": name, "domain_path": domain_path, "address": address, "user": user,
               "port": port, "protocol": protocol, "groups": groups, "tags": tags}

    if confirm_token:
        pending = confirmations.consume(confirm_token)
        if pending is None or pending.action != "add_host" or pending.payload != payload:
            return "confirm_token inválido ou expirado — chame add_host de novo sem confirm_token para reiniciar"
    else:
        pending = confirmations.create("add_host", payload, "sensitive",
                                       "escrita de inventário sempre exige confirmação", "mcp:inventory_connector")
        audit.record("add_host", actor="mcp:inventory_connector", risk="sensitive", status="confirmation_required",
                     detail=payload)
        return (f"CONFIRMAÇÃO NECESSÁRIA. Chame add_host de novo com os mesmos argumentos mais "
                f"confirm_token='{pending.token}' para gravar em domain/{domain_path}/{name}/host.yaml.")

    inv = Inventory()
    data = {
        "address": address,
        "user": user,
        "port": port,
        "protocol": protocol,
        "groups": [g for g in groups.split(",") if g],
        "tags": [t for t in tags.split(",") if t],
        "identity_file": None,
    }
    host_dir = inv.save(name, data, domain_path=domain_path)
    audit.record("add_host", actor="mcp:inventory_connector", risk="sensitive", status="executed", detail=payload)
    return f"host '{name}' salvo em {host_dir}/host.yaml"


if __name__ == "__main__":
    mcp.run()
