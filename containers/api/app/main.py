"""subot-api — superfície REST espelhando a CLI/os servidores MCP, para que humanos ou automação
sem IA possam disparar as mesmas operações com os mesmos controles de segurança dos agentes."""
from __future__ import annotations

from typing import Any

from fastapi import FastAPI, HTTPException
from pydantic import BaseModel
from subot_core import Inventory, SSHGateway, audit
from subot_orchestrator.agent_loader import load_all
from subot_orchestrator.delegator import delegate
from subot_orchestrator.runner import run_agent

app = FastAPI(title="subot-api", version="0.1.0")
gateway = SSHGateway()


@app.get("/health")
def health() -> dict:
    return {"status": "ok"}


@app.get("/hosts")
def list_hosts(group: str | None = None) -> list[dict]:
    hosts = Inventory().list(group=group)
    return [h.__dict__ for h in hosts]


class SSHExecRequest(BaseModel):
    host: str
    command: str
    confirm_token: str | None = None
    actor: str = "api"


@app.post("/ssh/exec")
def ssh_exec(req: SSHExecRequest) -> dict:
    try:
        result = gateway.exec(req.host, req.command, actor=req.actor, confirm_token=req.confirm_token)
    except KeyError as exc:
        raise HTTPException(404, str(exc)) from exc
    return result.__dict__


@app.get("/audit")
def get_audit(since: str | None = None, until: str | None = None, event: str | None = None,
              limit: int = 200) -> list[dict]:
    return audit.query(since=since, until=until, event=event, limit=limit)


@app.get("/agents")
def list_agents() -> list[dict]:
    specs = load_all()
    return [
        {"name": s.name, "description": s.description, "provider": s.provider, "model": s.model, "tools": s.tools}
        for s in specs.values()
    ]


class AgentRunRequest(BaseModel):
    task: str


@app.post("/agents/{name}/run")
async def agent_run(name: str, req: AgentRunRequest) -> dict:
    try:
        result = await run_agent(name, req.task, actor="api")
    except KeyError as exc:
        raise HTTPException(404, str(exc)) from exc
    return result.__dict__


class DelegateRequest(BaseModel):
    tasks: dict[str, str]


@app.post("/delegate")
async def delegate_route(req: DelegateRequest) -> dict[str, Any]:
    results = await delegate(req.tasks, actor="api")
    return {name: r.__dict__ for name, r in results.items()}
