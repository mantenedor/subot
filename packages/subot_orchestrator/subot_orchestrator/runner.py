"""Executa um agente canônico (agents/*.md) contra o provedor de IA configurado, dando a ele
acesso às mesmas ferramentas MCP que o Claude Code usaria. Requer um modelo com suporte a
tool-calling (ex.: qwen2.5/llama3.1 no Ollama, ou qualquer modelo remoto moderno) — ver README."""
from __future__ import annotations

import asyncio
import json
from dataclasses import dataclass

import litellm

from .agent_loader import load_all
from .mcp_client import MCPToolClient
from .providers import ProviderRegistry

MAX_TOOL_ITERATIONS = 8


@dataclass
class RunResult:
    agent: str
    provider: str
    model: str
    output: str
    tool_calls: int = 0


async def _tool_schemas(tool_servers: list[str]) -> tuple[list[dict], dict[str, str]]:
    """Retorna (definições de tool no formato OpenAI, {nome_da_tool: servidor_dono})."""
    defs: list[dict] = []
    owner: dict[str, str] = {}
    for server in tool_servers:
        async with MCPToolClient(server) as client:
            assert client.session is not None
            result = await client.session.list_tools()
            for tool in result.tools:
                defs.append({
                    "type": "function",
                    "function": {
                        "name": tool.name,
                        "description": tool.description or "",
                        "parameters": tool.inputSchema or {"type": "object", "properties": {}},
                    },
                })
                owner[tool.name] = server
    return defs, owner


async def run_agent(name: str, task: str, *, actor: str = "orchestrator") -> RunResult:
    agents = load_all()
    if name not in agents:
        raise KeyError(f"agente desconhecido '{name}' — confira agents/*.md")
    spec = agents[name]
    registry = ProviderRegistry()
    tool_defs, tool_owner = await _tool_schemas(spec.tools)

    messages: list[dict] = [
        {"role": "system", "content": spec.system_prompt},
        {"role": "user", "content": task},
    ]

    chain = [f"{spec.provider}:{spec.model}"] + list(spec.fallback)
    last_error: Exception | None = None

    for target in chain:
        provider_id, model = target.split(":", 1)
        try:
            model_str, kwargs = registry.litellm_target(provider_id, model)
        except Exception as exc:  # noqa: BLE001 - provedor mal configurado, tenta o próximo da cadeia
            last_error = exc
            continue

        try:
            tool_calls_used = 0
            for _ in range(MAX_TOOL_ITERATIONS):
                response = await asyncio.to_thread(
                    litellm.completion,
                    model=model_str,
                    messages=messages,
                    tools=tool_defs or None,
                    temperature=spec.temperature,
                    **kwargs,
                )
                choice = response.choices[0].message
                tool_calls = getattr(choice, "tool_calls", None)

                assistant_msg: dict = {"role": "assistant", "content": choice.content or ""}
                if tool_calls:
                    assistant_msg["tool_calls"] = [
                        {"id": c.id, "type": "function",
                         "function": {"name": c.function.name, "arguments": c.function.arguments}}
                        for c in tool_calls
                    ]
                messages.append(assistant_msg)

                if not tool_calls:
                    return RunResult(agent=name, provider=provider_id, model=model,
                                      output=choice.content or "", tool_calls=tool_calls_used)

                for call in tool_calls:
                    server = tool_owner.get(call.function.name)
                    args = json.loads(call.function.arguments or "{}")
                    if server is None:
                        tool_result = f"erro: nenhum servidor MCP dono da tool '{call.function.name}'"
                    else:
                        async with MCPToolClient(server) as client:
                            tool_result = await client.call(call.function.name, args)
                    tool_calls_used += 1
                    messages.append({"role": "tool", "tool_call_id": call.id, "content": tool_result})

            return RunResult(agent=name, provider=provider_id, model=model,
                              output="(interrompido: limite de iterações de tool atingido)",
                              tool_calls=tool_calls_used)
        except Exception as exc:  # noqa: BLE001 - tenta o próximo provedor da cadeia de fallback
            last_error = exc
            continue

    raise RuntimeError(f"agente '{name}' falhou em todos os provedores de {chain}: {last_error}")
