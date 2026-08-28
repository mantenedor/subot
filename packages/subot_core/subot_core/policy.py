"""Motor de política — o portão pelo qual toda ação sobre a infraestrutura precisa passar.

Classifica um comando em safe / sensitive / destructive / blocked a partir de
config/policy/allowlist.yaml e config/policy/destructive_patterns.yaml. Comandos que não batem em
nenhum padrão conhecido são tratados como 'sensitive' por padrão (fail-closed) — nunca como safe.
"""
from __future__ import annotations

import fnmatch
import os
import re
from dataclasses import dataclass
from enum import Enum
from pathlib import Path

import yaml

ALLOWLIST_PATH = Path(os.environ.get("SUBOT_ALLOWLIST_FILE", "/opt/subot/config/policy/allowlist.yaml"))
DESTRUCTIVE_PATH = Path(os.environ.get("SUBOT_DESTRUCTIVE_FILE", "/opt/subot/config/policy/destructive_patterns.yaml"))


class Risk(str, Enum):
    SAFE = "safe"
    SENSITIVE = "sensitive"
    DESTRUCTIVE = "destructive"
    BLOCKED = "blocked"


@dataclass
class Decision:
    risk: Risk
    reason: str


class PolicyEngine:
    def __init__(self, allowlist_path: Path = ALLOWLIST_PATH, destructive_path: Path = DESTRUCTIVE_PATH):
        self.allowlist_path = Path(allowlist_path)
        self.destructive_path = Path(destructive_path)
        self.reload()

    def reload(self) -> None:
        self._safe_patterns = self._load_patterns(self.allowlist_path, "safe_patterns")
        self._sensitive_patterns = self._load_patterns(self.allowlist_path, "sensitive_patterns")
        self._destructive_patterns = self._load_patterns(self.destructive_path, "destructive_patterns")
        self._blocked_patterns = self._load_patterns(self.destructive_path, "blocked_patterns")

    @staticmethod
    def _load_patterns(path: Path, key: str) -> list[str]:
        if not path.exists():
            return []
        data = yaml.safe_load(path.read_text(encoding="utf-8")) or {}
        return list(data.get(key, []))

    @staticmethod
    def _matches(command: str, patterns: list[str]) -> str | None:
        for pattern in patterns:
            if pattern.startswith("re:"):
                if re.search(pattern[3:], command):
                    return pattern
            elif fnmatch.fnmatch(command, pattern):
                return pattern
        return None

    def classify(self, command: str, *, host_is_protected: bool = False) -> Decision:
        command = command.strip()

        if match := self._matches(command, self._blocked_patterns):
            return Decision(Risk.BLOCKED, f"corresponde ao padrão bloqueado '{match}'")

        if match := self._matches(command, self._destructive_patterns):
            return Decision(Risk.DESTRUCTIVE, f"corresponde ao padrão destrutivo '{match}'")

        if match := self._matches(command, self._sensitive_patterns):
            return Decision(Risk.SENSITIVE, f"corresponde ao padrão sensível '{match}'")

        if match := self._matches(command, self._safe_patterns):
            if host_is_protected:
                return Decision(Risk.SENSITIVE, f"padrão safe '{match}', mas host é protected/prod")
            return Decision(Risk.SAFE, f"corresponde ao padrão safe '{match}'")

        return Decision(Risk.SENSITIVE, "nenhum padrão da allowlist corresponde — default é exigir confirmação")
