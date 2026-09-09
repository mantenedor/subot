"""Inventário de hosts gerenciados, carregado de config/hosts.yaml."""
from __future__ import annotations

import os
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

import yaml

DEFAULT_HOSTS_PATH = Path(os.environ.get("SUBOT_HOSTS_FILE", "/opt/subot/config/hosts.yaml"))


@dataclass
class Host:
    name: str
    address: str
    port: int = 22
    user: str = "root"
    protocol: str = "ssh"
    groups: list[str] = field(default_factory=list)
    tags: list[str] = field(default_factory=list)
    identity_file: str | None = None

    @property
    def is_protected(self) -> bool:
        return "protected" in self.tags or "prod" in self.tags


class Inventory:
    def __init__(self, path: Path | str = DEFAULT_HOSTS_PATH):
        self.path = Path(path)
        self._hosts: dict[str, Host] = {}
        self.reload()

    def reload(self) -> None:
        if not self.path.exists():
            self._hosts = {}
            return
        raw = yaml.safe_load(self.path.read_text(encoding="utf-8")) or {}
        hosts: dict[str, Host] = {}
        for name, data in (raw.get("hosts") or {}).items():
            hosts[name] = Host(
                name=name,
                address=data["address"],
                port=int(data.get("port", 22)),
                user=data.get("user", "root"),
                protocol=data.get("protocol", "ssh"),
                groups=list(data.get("groups", [])),
                tags=list(data.get("tags", [])),
                identity_file=data.get("identity_file"),
            )
        self._hosts = hosts

    def get(self, name: str) -> Host:
        try:
            return self._hosts[name]
        except KeyError:
            raise KeyError(f"host '{name}' não encontrado no inventário ({self.path})") from None

    def list(self, group: str | None = None) -> list[Host]:
        hosts = list(self._hosts.values())
        if group:
            hosts = [h for h in hosts if group in h.groups]
        return hosts

    def save(self, hosts: dict[str, dict[str, Any]]) -> None:
        """Persiste o inventário completo de volta em config/hosts.yaml. Sobrescreve o arquivo —
        o chamador é responsável por montar o dict completo (ver inventory_connector.add_host)."""
        self.path.parent.mkdir(parents=True, exist_ok=True)
        self.path.write_text(
            yaml.safe_dump({"hosts": hosts}, sort_keys=True, allow_unicode=True),
            encoding="utf-8",
        )
        self.reload()
