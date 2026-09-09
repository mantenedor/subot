"""Protocolo de confirmação em duas etapas ('break-glass') para ações sensíveis/destrutivas.

Uma ação não-safe retorna um token de uso único em vez de executar. Uma segunda chamada explícita
com esse token executa de fato. Funciona independente da UI de permissão do Claude Code (defesa em
profundidade) e vale igualmente para a API REST e para agentes rodando em qualquer IA.
"""
from __future__ import annotations

import json
import os
import secrets
import time
from dataclasses import asdict, dataclass
from pathlib import Path
from typing import Any

STORE_PATH = Path(os.environ.get("SUBOT_CONFIRM_STORE", "/opt/subot/data/audit/.confirm_tokens.json"))
DEFAULT_TTL = int(os.environ.get("SUBOT_CONFIRM_TOKEN_TTL_SECONDS", "300"))


@dataclass
class PendingAction:
    token: str
    action: str
    payload: dict[str, Any]
    risk: str
    reason: str
    requested_by: str
    created_at: float
    expires_at: float


class ConfirmationStore:
    def __init__(self, path: Path = STORE_PATH, ttl: int = DEFAULT_TTL):
        self.path = Path(path)
        self.ttl = ttl
        self.path.parent.mkdir(parents=True, exist_ok=True)

    def _read(self) -> dict[str, dict]:
        if not self.path.exists():
            return {}
        try:
            return json.loads(self.path.read_text(encoding="utf-8"))
        except json.JSONDecodeError:
            return {}

    def _write(self, data: dict[str, dict]) -> None:
        tmp = self.path.with_suffix(".tmp")
        tmp.write_text(json.dumps(data, indent=2), encoding="utf-8")
        tmp.replace(self.path)

    @staticmethod
    def _purge_expired(data: dict[str, dict]) -> dict[str, dict]:
        now = time.time()
        return {k: v for k, v in data.items() if v["expires_at"] > now}

    def create(self, action: str, payload: dict[str, Any], risk: str, reason: str, requested_by: str) -> PendingAction:
        now = time.time()
        pending = PendingAction(
            token=secrets.token_urlsafe(24),
            action=action,
            payload=payload,
            risk=risk,
            reason=reason,
            requested_by=requested_by,
            created_at=now,
            expires_at=now + self.ttl,
        )
        data = self._purge_expired(self._read())
        data[pending.token] = asdict(pending)
        self._write(data)
        return pending

    def consume(self, token: str) -> PendingAction | None:
        """Recupera e invalida um token (uso único). Retorna None se inválido/expirado."""
        data = self._purge_expired(self._read())
        raw = data.pop(token, None)
        self._write(data)
        return PendingAction(**raw) if raw else None

    def peek(self, token: str) -> PendingAction | None:
        data = self._purge_expired(self._read())
        raw = data.get(token)
        return PendingAction(**raw) if raw else None
