"""Coordena múltiplos agentes — potencialmente em provedores de IA diferentes — rodando em
paralelo, agregando os resultados por nome de agente."""
from __future__ import annotations

import asyncio

from .runner import RunResult, run_agent


async def delegate(tasks: dict[str, str], *, actor: str = "orchestrator") -> dict[str, RunResult]:
    """tasks: {nome_do_agente: descrição_da_tarefa}. Roda todos os agentes em paralelo, cada um no
    provider/model declarado em seu próprio agents/*.md, e retorna um resultado por agente."""
    names = list(tasks)
    results = await asyncio.gather(
        *(run_agent(name, tasks[name], actor=actor) for name in names),
        return_exceptions=True,
    )
    out: dict[str, RunResult] = {}
    for name, result in zip(names, results):
        if isinstance(result, Exception):
            out[name] = RunResult(agent=name, provider="?", model="?", output=f"ERRO: {result}")
        else:
            out[name] = result
    return out
