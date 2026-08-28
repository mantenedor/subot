"""Carregamento de chaves SSH com verificação de permissões.

Por padrão apenas AVISA (não bloqueia) sobre uma chave privada com permissões inseguras, porque
diretórios montados a partir de um host Windows via Docker Desktop nem sempre conseguem expressar
permissões POSIX com precisão. Ative SUBOT_STRICT_KEY_PERMS=true depois de validar que 'chmod 600'
é respeitado no seu ambiente (ex.: WSL2) para transformar o aviso em bloqueio de fato.
"""
from __future__ import annotations

import os
import stat
from pathlib import Path

SSH_DIR = Path(os.environ.get("SUBOT_SSH_DIR", "/opt/subot/secrets/ssh"))
STRICT = os.environ.get("SUBOT_STRICT_KEY_PERMS", "false").lower() == "true"


class InsecureKeyPermissions(RuntimeError):
    pass


def _check_permissions(path: Path) -> None:
    mode = stat.S_IMODE(path.stat().st_mode)
    if mode & (stat.S_IRWXG | stat.S_IRWXO):
        message = f"{path} está legível/gravável por grupo ou outros (modo {oct(mode)}); rode 'chmod 600 {path}'"
        if STRICT:
            raise InsecureKeyPermissions(message)
        print(f"[subot_core.secrets] AVISO: {message}", flush=True)


def default_identity(host_identity_file: str | None = None) -> Path:
    if host_identity_file:
        path = Path(host_identity_file)
        if not path.is_absolute():
            path = SSH_DIR / path
    else:
        path = SSH_DIR / "bastion_id_ed25519"
    if not path.exists():
        raise FileNotFoundError(f"chave de identidade SSH não encontrada: {path}")
    _check_permissions(path)
    return path


def known_hosts_path() -> Path:
    path = SSH_DIR / "known_hosts"
    path.parent.mkdir(parents=True, exist_ok=True)
    path.touch(exist_ok=True)
    return path


def key_passphrase() -> str | None:
    """Passphrase da chave privada do bastião — NUNCA fica salva em arquivo (nem em .env por
    padrão). É fornecida ao container só como variável de ambiente no momento do
    'docker compose up', então só existe na memória do processo em execução. Se a chave foi
    gerada sem passphrase (rodando fora do fluxo padrão de scripts/setup.sh), retorna None e o
    paramiko simplesmente carrega a chave sem tentar descriptografá-la."""
    return os.environ.get("SUBOT_SSH_KEY_PASSPHRASE") or None
