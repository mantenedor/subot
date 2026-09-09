"""Inventário de hosts gerenciados, carregado de domain/ — um host.yaml por host, em
domain/<domínio>/<região>/<zona>/<pod>/<cluster>/<hostname>/host.yaml (os níveis intermediários
são livres; a busca é recursiva por nome de arquivo)."""
from __future__ import annotations

import os
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

import yaml

DEFAULT_DOMAIN_DIR = Path(os.environ.get("SUBOT_DOMAIN_DIR", "/opt/subot/domain"))


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
    dir: Path | None = None

    @property
    def is_protected(self) -> bool:
        return "protected" in self.tags or "prod" in self.tags


class Inventory:
    def __init__(self, path: Path | str = DEFAULT_DOMAIN_DIR):
        self.path = Path(path)
        self._hosts: dict[str, Host] = {}
        self.reload()

    def reload(self) -> None:
        hosts: dict[str, Host] = {}
        if self.path.exists():
            for host_yaml in self.path.rglob("host.yaml"):
                data = yaml.safe_load(host_yaml.read_text(encoding="utf-8")) or {}
                name = host_yaml.parent.name
                hosts[name] = Host(
                    name=name,
                    address=data["address"],
                    port=int(data.get("port", 22)),
                    user=data.get("user", "root"),
                    protocol=data.get("protocol", "ssh"),
                    groups=list(data.get("groups", [])),
                    tags=list(data.get("tags", [])),
                    identity_file=data.get("identity_file"),
                    dir=host_yaml.parent,
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

    def host_dir(self, name: str) -> Path:
        """Diretório-folha domain/.../<name>/ onde host.yaml (e role.json, se houver) vivem."""
        return self.get(name).dir

    def save(self, name: str, data: dict[str, Any], domain_path: str | None = None) -> Path:
        """Cria/atualiza domain/<domain_path>/<name>/host.yaml. domain_path é a cadeia
        domínio/região/zona/pod/cluster separada por '/' (ex.: 'on-prem'), sem incluir o nome do
        host — só é obrigatório para hosts novos; hosts já existentes reaproveitam seu diretório
        atual e ignoram domain_path. Retorna o Path do diretório-folha resultante."""
        existing = self._hosts.get(name)
        if existing is not None:
            host_dir = existing.dir
        else:
            if not domain_path:
                raise ValueError(f"host '{name}' é novo — domain_path (ex.: 'on-prem') é obrigatório")
            host_dir = self.path.joinpath(*domain_path.strip("/").split("/"), name)
        host_dir.mkdir(parents=True, exist_ok=True)
        (host_dir / "host.yaml").write_text(
            yaml.safe_dump(data, sort_keys=True, allow_unicode=True),
            encoding="utf-8",
        )
        self.reload()
        return host_dir
