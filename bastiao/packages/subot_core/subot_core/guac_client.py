"""Cliente mínimo da REST API do Guacamole — cria/lista conexões e monta o link de sessão web."""
from __future__ import annotations

import base64
import os
import time
from dataclasses import dataclass

import requests

BASE_URL = os.environ.get("GUACAMOLE_BASE_URL", "http://guacamole:8080/guacamole")
DATA_SOURCE = os.environ.get("GUACAMOLE_DATA_SOURCE", "postgresql")


@dataclass
class GuacSession:
    token: str
    expires_at: float


class GuacamoleClient:
    def __init__(self, base_url: str = BASE_URL, username: str | None = None, password: str | None = None):
        self.base_url = base_url.rstrip("/")
        self.username = username or os.environ.get("GUACAMOLE_ADMIN_USER", "guacadmin")
        self.password = password or os.environ.get("GUACAMOLE_ADMIN_PASSWORD", "")
        self._session: GuacSession | None = None

    def _authenticate(self) -> str:
        if self._session and self._session.expires_at > time.time():
            return self._session.token
        resp = requests.post(
            f"{self.base_url}/api/tokens",
            data={"username": self.username, "password": self.password},
            timeout=10,
        )
        resp.raise_for_status()
        token = resp.json()["authToken"]
        self._session = GuacSession(token=token, expires_at=time.time() + 55 * 60)
        return token

    def list_connections(self) -> dict:
        token = self._authenticate()
        resp = requests.get(
            f"{self.base_url}/api/session/data/{DATA_SOURCE}/connections",
            params={"token": token},
            timeout=10,
        )
        resp.raise_for_status()
        return resp.json()

    def create_connection(self, name: str, protocol: str, parameters: dict, *, group_id: str = "ROOT") -> dict:
        token = self._authenticate()
        payload = {
            "parentIdentifier": group_id,
            "name": name,
            "protocol": protocol,
            "parameters": parameters,
            "attributes": {},
        }
        resp = requests.post(
            f"{self.base_url}/api/session/data/{DATA_SOURCE}/connections",
            params={"token": token},
            json=payload,
            timeout=10,
        )
        resp.raise_for_status()
        return resp.json()

    def connection_url(self, connection_id: str) -> str:
        # A URL client-side do Guacamole usa um identificador base64 de "<id>\0c\0<datasource>".
        raw = f"{connection_id}\x00c\x00{DATA_SOURCE}".encode()
        ident = base64.b64encode(raw).decode()
        return f"{self.base_url}/#/client/{ident}"
