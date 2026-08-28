"""Registro de provedores de IA (config/providers.yaml) — resolve provider+model de um agente
para um alvo de chamada do LiteLLM. 'ollama' é local e não exige chave; provedores remotos só
ficam disponíveis quando a variável de ambiente correspondente está preenchida em .env."""
from __future__ import annotations

import os
import re
from dataclasses import dataclass
from pathlib import Path

import yaml

PROVIDERS_PATH = Path(os.environ.get("SUBOT_PROVIDERS_FILE", "/opt/subot/config/providers.yaml"))

_ENV_PATTERN = re.compile(r"\$\{([A-Z0-9_]+)(:-([^}]*))?\}")


def _expand_env(value: str | None) -> str | None:
    if value is None:
        return None

    def repl(match: re.Match) -> str:
        name, _, default = match.groups()
        return os.environ.get(name, default or "")

    return _ENV_PATTERN.sub(repl, value)


@dataclass
class ProviderConfig:
    id: str
    type: str
    base_url: str | None = None
    api_key_env: str | None = None
    default_model: str | None = None

    @property
    def api_key(self) -> str | None:
        return os.environ.get(self.api_key_env) if self.api_key_env else None


class ProviderRegistry:
    def __init__(self, path: Path = PROVIDERS_PATH):
        self.path = Path(path)
        self.reload()

    def reload(self) -> None:
        data = yaml.safe_load(self.path.read_text(encoding="utf-8")) if self.path.exists() else {}
        data = data or {}
        self._providers: dict[str, ProviderConfig] = {}
        for pid, cfg in (data.get("providers") or {}).items():
            self._providers[pid] = ProviderConfig(
                id=pid,
                type=cfg["type"],
                base_url=_expand_env(cfg.get("base_url")),
                api_key_env=cfg.get("api_key_env"),
                default_model=cfg.get("default_model"),
            )
        self.default_id: str = data.get("default", next(iter(self._providers), ""))

    def get(self, provider_id: str) -> ProviderConfig:
        try:
            return self._providers[provider_id]
        except KeyError:
            raise KeyError(f"provedor de IA desconhecido '{provider_id}' — confira config/providers.yaml") from None

    def available(self) -> list[ProviderConfig]:
        """Provedores utilizáveis agora: locais sempre; remotos só se a chave estiver definida."""
        out = []
        for p in self._providers.values():
            if p.type in ("ollama", "openai_compat") and not p.api_key_env:
                out.append(p)
            elif p.api_key:
                out.append(p)
        return out

    def litellm_target(self, provider_id: str, model: str) -> tuple[str, dict]:
        """Retorna (model_string_do_litellm, kwargs_extras) prontos para litellm.completion()."""
        p = self.get(provider_id)
        model = model or p.default_model or ""

        if p.type == "ollama":
            return f"ollama/{model}", {"api_base": p.base_url}

        if p.type == "openai_compat":
            if not p.base_url:
                raise RuntimeError(f"provedor '{provider_id}' sem base_url configurado (defina em .env)")
            kwargs: dict = {"api_base": p.base_url}
            if p.api_key:
                kwargs["api_key"] = p.api_key
            return f"openai/{model}", kwargs

        if p.type == "anthropic":
            if not p.api_key:
                raise RuntimeError(f"provedor '{provider_id}' precisa de {p.api_key_env} definido em .env")
            return f"anthropic/{model}", {"api_key": p.api_key}

        if p.type == "openai":
            if not p.api_key:
                raise RuntimeError(f"provedor '{provider_id}' precisa de {p.api_key_env} definido em .env")
            return f"openai/{model}", {"api_key": p.api_key}

        raise ValueError(f"tipo de provedor não suportado '{p.type}'")
