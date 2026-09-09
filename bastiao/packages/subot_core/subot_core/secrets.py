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
ENV_FILE = Path(os.environ.get("SUBOT_ENV_FILE", "/opt/subot/.env"))


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
    # 'secrets/ssh' é montado somente-leitura por design (ver ARCHITECTURE.md, Controles de
    # segurança item 6) — só tenta criar o diretório/arquivo quando ele ainda não existe (dev
    # local sem o mount ainda montado); quando já existe (caso comum, inclusive em produção),
    # mkdir/touch tentariam escrever num mount ro e falhariam com PermissionError mesmo com
    # exist_ok=True (que só engole FileExistsError, não PermissionError).
    if not path.exists():
        path.parent.mkdir(parents=True, exist_ok=True)
        path.touch(exist_ok=True)
    return path


def _read_passphrase_from_env_file() -> str | None:
    try:
        lines = ENV_FILE.read_text().splitlines()
    except OSError:
        return None
    for line in lines:
        line = line.strip()
        if line.startswith("SUBOT_SSH_KEY_PASSPHRASE="):
            return line.split("=", 1)[1].strip() or None
    return None


def key_passphrase() -> str | None:
    """Passphrase da chave privada do bastião. Lida direto de ENV_FILE (montado só-leitura, ver
    docker-compose.yml) a cada chamada, não de uma cópia fixada na criação do processo — assim
    trocar o valor no .env (ex.: rotação de chave) tem efeito imediato, sem recriar o container.
    Cai para a variável de ambiente só se o arquivo não existir (ex.: exportada manualmente antes
    do 'docker compose up', sem preencher o .env). Se a chave foi gerada sem passphrase (rodando
    fora do fluxo padrão de scripts/setup.sh), retorna None e o paramiko simplesmente carrega a
    chave sem tentar descriptografá-la."""
    return _read_passphrase_from_env_file() or os.environ.get("SUBOT_SSH_KEY_PASSPHRASE") or None
