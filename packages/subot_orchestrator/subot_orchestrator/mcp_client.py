"""Cliente MCP genérico — permite que o subot_orchestrator chame os mesmos servidores MCP que o
Claude Code usaria, via stdio, sem depender do Claude Code para funcionar."""
from __future__ import annotations

import os
import sys
from contextlib import AsyncExitStack
from pathlib import Path

from mcp import ClientSession, StdioServerParameters
from mcp.client.stdio import stdio_client

MCP_SERVERS_DIR = Path(os.environ.get("SUBOT_MCP_SERVERS_DIR", "/opt/subot/mcp-servers"))

SERVER_ENTRYPOINTS = {
    "ssh_connector": "ssh_connector/server.py",
    "remote_desktop_connector": "remote_desktop_connector/server.py",
    "inventory_connector": "inventory_connector/server.py",
    "audit_connector": "audit_connector/server.py",
}


class MCPToolClient:
    """Conecta a um servidor MCP via stdio pela duração de um bloco `async with`."""

    def __init__(self, server_name: str):
        if server_name not in SERVER_ENTRYPOINTS:
            raise ValueError(f"servidor MCP desconhecido '{server_name}' (conhecidos: {sorted(SERVER_ENTRYPOINTS)})")
        self.server_name = server_name
        self._stack = AsyncExitStack()
        self.session: ClientSession | None = None

    async def __aenter__(self) -> "MCPToolClient":
        script = MCP_SERVERS_DIR / SERVER_ENTRYPOINTS[self.server_name]
        params = StdioServerParameters(command=sys.executable, args=[str(script)], env=dict(os.environ))
        read, write = await self._stack.enter_async_context(stdio_client(params))
        self.session = await self._stack.enter_async_context(ClientSession(read, write))
        await self.session.initialize()
        return self

    async def __aexit__(self, *exc) -> None:
        await self._stack.aclose()

    async def list_tools(self) -> list[str]:
        assert self.session is not None
        result = await self.session.list_tools()
        return [t.name for t in result.tools]

    async def call(self, tool: str, arguments: dict) -> str:
        assert self.session is not None
        result = await self.session.call_tool(tool, arguments)
        return "\n".join(part.text for part in result.content if hasattr(part, "text"))


async def call_tool(server_name: str, tool: str, arguments: dict) -> str:
    async with MCPToolClient(server_name) as client:
        return await client.call(tool, arguments)
