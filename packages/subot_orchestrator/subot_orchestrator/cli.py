"""CLI `subot` — ponto de entrada agnóstico de IA para listar e rodar agentes, seja qual for o
provedor (local ou remoto) declarado em cada ia/agents/*.md."""
from __future__ import annotations

import asyncio
import base64
import json
import os
from pathlib import Path

import typer
from subot_core import Inventory, PolicyEngine, SSHGateway

from .agent_loader import load_all
from .delegator import delegate
from .runner import run_agent

app = typer.Typer(help="subot: orquestrador multi-IA do bastião de infraestrutura")
agent_app = typer.Typer(help="Inspeciona e roda agentes canônicos (ia/agents/*.md)")
identity_app = typer.Typer(help="Identidade (usuário/chave/sudoers) da IA nos hosts geridos")
app.add_typer(agent_app, name="agent")
app.add_typer(identity_app, name="identity")

MANAGED_IDENTITY_PATH = Path(os.environ.get(
    "SUBOT_MANAGED_IDENTITY_FILE", "/opt/subot/ia/policy/managed-identity.json"))
HOST_IDENTITY_DIR = Path(os.environ.get(
    "SUBOT_HOST_IDENTITY_DIR", "/opt/subot/config/policy/hosts"))


def _load_identity_json(path: Path) -> dict:
    if not path.exists():
        return {}
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except json.JSONDecodeError as exc:
        typer.echo(f"{path} não é JSON válido: {exc}")
        raise typer.Exit(1) from exc


@agent_app.command("list")
def agent_list() -> None:
    specs = load_all()
    if not specs:
        typer.echo("nenhum agente encontrado em ia/agents/*.md")
        raise typer.Exit(1)
    for spec in specs.values():
        tools = ",".join(spec.tools)
        typer.echo(f"{spec.name:20s} provider={spec.provider:10s} model={spec.model:20s} tools={tools}")


@agent_app.command("run")
def agent_run(name: str, task: str) -> None:
    result = asyncio.run(run_agent(name, task))
    typer.echo(json.dumps(result.__dict__, indent=2, ensure_ascii=False))


@app.command("delegate")
def delegate_cmd(
    pairs: list[str] = typer.Argument(..., help="pares agente=tarefa, ex: stack-maintainer='health check'"),
) -> None:
    tasks: dict[str, str] = {}
    for pair in pairs:
        name, _, task = pair.partition("=")
        if not task:
            raise typer.BadParameter(f"esperado agente=tarefa, recebido '{pair}'")
        tasks[name] = task
    results = asyncio.run(delegate(tasks))
    typer.echo(json.dumps({k: v.__dict__ for k, v in results.items()}, indent=2, ensure_ascii=False))


@identity_app.command("sync")
def identity_sync(
    host: str = typer.Option(..., "--host", help="nome do host no inventário (config/hosts.yaml)"),
) -> None:
    """Mescla ia/policy/managed-identity.json (padrão) + config/policy/hosts/<host>.json
    (complemento, se existir) e aplica o sudoers resultante nesse host — sempre via Gate
    (aprovação humana assíncrona, mesmo em hosts já provisionados). v1: um host por vez."""
    inventory = Inventory()
    inventory.get(host)  # levanta KeyError com mensagem clara se o host não existir

    default = _load_identity_json(MANAGED_IDENTITY_PATH)
    if not default:
        typer.echo(f"{MANAGED_IDENTITY_PATH} não existe ou está vazio — rode scripts/setup.sh primeiro.")
        raise typer.Exit(1)
    username = default.get("username", "subot")
    host_specific = _load_identity_json(HOST_IDENTITY_DIR / f"{host}.json")
    merged = list(default.get("sudoers", [])) + list(host_specific.get("sudoers", []))

    missing_key = [i for i, s in enumerate(merged) if "pattern" not in s]
    if missing_key:
        typer.echo(f"RECUSADO — {len(missing_key)} entrada(s) de sudoers sem a chave 'pattern' "
                   f"(índices {missing_key} na lista mesclada) — corrija o manifesto.")
        raise typer.Exit(1)

    # Dedup preservando ordem — o mesmo padrão pode aparecer no manifesto padrão e no do host sem
    # que isso seja um erro (ex.: promovido cedo no padrão, depois também listado no host por
    # engano); não faz sentido mandar a mesma regra duas vezes pro sudoers gerado.
    seen: set[str] = set()
    sudoers = []
    for entry in merged:
        pattern = entry["pattern"]
        if pattern in seen:
            continue
        seen.add(pattern)
        sudoers.append(entry)

    policy = PolicyEngine()
    sensitive = set(policy.list_sensitive_patterns())
    invalid = [s["pattern"] for s in sudoers if s["pattern"] not in sensitive]
    if invalid:
        typer.echo("RECUSADO — os padrões abaixo não estão em sensitive_patterns (allowlist.yaml) e não "
                   "podem ser promovidos (edite allowlist.yaml primeiro, ou corrija o manifesto):")
        for pattern in invalid:
            typer.echo(f"  - {pattern}")
        raise typer.Exit(1)

    if not sudoers:
        typer.echo(f"nenhum padrão de sudoers para '{host}' (nem em {MANAGED_IDENTITY_PATH.name}, "
                   f"nem em hosts/{host}.json) — nada a aplicar.")
        raise typer.Exit(0)

    payload = {
        "username": username,
        "sudoers": sudoers,
        "destructive_patterns": policy.list_destructive_patterns(),
        "blocked_patterns": policy.list_blocked_patterns(),
    }
    payload_b64 = base64.b64encode(json.dumps(payload, ensure_ascii=False).encode("utf-8")).decode("ascii")
    summary = ", ".join(s["pattern"] for s in sudoers)
    reason = f"aplicar política sudoers para '{username}' em '{host}': {summary}"

    typer.echo(f"==> propondo {len(sudoers)} padrão(ões) para '{host}': {summary}")
    typer.echo("    isso vai pedir aprovação humana em tempo real (Gate/Telegram no host) — pode levar minutos.")
    gateway = SSHGateway(inventory=inventory, policy=policy)
    result = gateway.propose_sudoers_policy(host, payload_b64, reason=reason, actor="cli:subot-identity-sync")
    if result.status == "executed":
        typer.echo(f"exit_code={result.exit_code}\n--- stdout ---\n{result.stdout}\n--- stderr ---\n{result.stderr}")
        if result.exit_code != 0:
            raise typer.Exit(1)
    else:
        typer.echo(f"{result.status}: {result.reason}")
        raise typer.Exit(1)


@identity_app.command("show")
def identity_show(host: str = typer.Argument(..., help="nome do host no inventário")) -> None:
    """Mostra o que já está de fato promovido no sudoers desse host (leitura, sem privilégio)."""
    inventory = Inventory()
    inventory.get(host)
    gateway = SSHGateway(inventory=inventory)
    result = gateway.show_sudoers(host, actor="cli:subot-identity-show")
    if result.status == "executed":
        typer.echo(result.stdout or "(sudo -n -l não retornou nada — nenhuma entrada promovida)")
    else:
        typer.echo(f"{result.status}: {result.reason}")
        raise typer.Exit(1)


def main() -> None:
    app()


if __name__ == "__main__":
    main()
