"""CLI `subot` — ponto de entrada agnóstico de IA para listar e rodar agentes, seja qual for o
provedor (local ou remoto) declarado em cada agents/*.md."""
from __future__ import annotations

import asyncio
import json

import typer

from .agent_loader import load_all
from .delegator import delegate
from .runner import run_agent

app = typer.Typer(help="subot: orquestrador multi-IA do bastião de infraestrutura")
agent_app = typer.Typer(help="Inspeciona e roda agentes canônicos (agents/*.md)")
app.add_typer(agent_app, name="agent")


@agent_app.command("list")
def agent_list() -> None:
    specs = load_all()
    if not specs:
        typer.echo("nenhum agente encontrado em agents/*.md")
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


def main() -> None:
    app()


if __name__ == "__main__":
    main()
