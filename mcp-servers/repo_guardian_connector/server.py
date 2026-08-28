#!/usr/bin/env python3
"""Servidor MCP de higiene e publicação do repositório do subot.

Diferente dos outros conectores (que operam a infraestrutura JÁ IMPLANTADA através do
subot_core), este atua sobre o próprio código-fonte do projeto, antes de ele ser publicado ou
atualizado no GitHub. Por isso é deliberadamente AUTO-CONTIDO — não importa subot_core nem exige
rodar dentro do container 'subot-agent' (que nem tem o .git montado). Basta:

    pip install mcp Pillow
    python mcp-servers/repo_guardian_connector/server.py

Estado próprio (log de auditoria + tokens de confirmação) fica em <raiz-do-repo>/.subot-guardian/,
que é ignorado pelo git.
"""
from __future__ import annotations

import collections
import ipaddress
import json
import math
import re
import secrets
import subprocess
import time
from dataclasses import asdict, dataclass
from pathlib import Path
from typing import Any

from mcp.server.fastmcp import FastMCP

mcp = FastMCP("subot-repo-guardian-connector")

MAX_SCAN_BYTES = 2_000_000
IMAGE_EXTENSIONS = {".png", ".jpg", ".jpeg", ".gif", ".bmp", ".webp", ".tiff", ".tif"}

REQUIRED_IGNORED_PATHS = ["secrets/", "data/", ".env", "config/hosts.yaml"]
# Exceções deliberadas: documentação sem conteúdo sensível que o próprio .gitignore re-inclui de
# propósito dentro de um path normalmente exigido como "todo ignorado" (ver .gitignore).
ALLOWED_TRACKED_UNDER_REQUIRED = {"secrets/ssh/README.md"}
SUSPICIOUS_NAME_PATTERNS = [
    re.compile(r"(?i)\.env(\..+)?$"),
    re.compile(r"(?i)id_(rsa|dsa|ecdsa|ed25519)$"),
    re.compile(r"(?i)\.(pem|key|pfx|p12)$"),
    re.compile(r"(?i)(^|/)(secret|password|credential)s?[._-]"),
    re.compile(r"(?i)htpasswd"),
]

HIGH_CONFIDENCE_NAMES = {"private_key", "aws_access_key", "slack_token"}
SECRET_PATTERNS: list[tuple[str, re.Pattern, str]] = [
    ("private_key", re.compile(r"-----BEGIN (?:RSA |EC |OPENSSH |DSA |PGP )?PRIVATE KEY-----"), "alta"),
    ("aws_access_key", re.compile(r"AKIA[0-9A-Z]{16}"), "alta"),
    ("slack_token", re.compile(r"xox[baprs]-[0-9A-Za-z-]{10,}"), "alta"),
    ("jwt", re.compile(r"eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}"), "media"),
    ("generic_secret_assignment",
     re.compile(r"(?i)\b(api[_-]?key|secret|token|passwd|password)\b\s*[:=]\s*['\"]([^'\"\s]{12,})['\"]"), "media"),
    ("ip_address", re.compile(r"\b(?:\d{1,3}\.){3}\d{1,3}\b"), "info"),
]


# ---------------------------------------------------------------------------
# Estado local (auditoria + confirmação em duas etapas) — auto-contido, sem depender de subot_core
# ---------------------------------------------------------------------------

def _repo_root() -> Path:
    try:
        out = subprocess.run(["git", "rev-parse", "--show-toplevel"], capture_output=True, text=True, check=True)
        return Path(out.stdout.strip())
    except Exception:
        return Path.cwd()


REPO_ROOT = _repo_root()
STATE_DIR = REPO_ROOT / ".subot-guardian"


def _audit(event: str, status: str, detail: dict[str, Any] | None = None) -> None:
    STATE_DIR.mkdir(parents=True, exist_ok=True)
    entry = {"ts": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), "event": event, "status": status,
              "detail": detail or {}}
    with (STATE_DIR / "audit.jsonl").open("a", encoding="utf-8") as fh:
        fh.write(json.dumps(entry, ensure_ascii=False) + "\n")


@dataclass
class _Pending:
    token: str
    action: str
    payload: dict[str, Any]
    expires_at: float


class _ConfirmStore:
    def __init__(self, path: Path = STATE_DIR / "confirm-tokens.json", ttl: int = 600):
        self.path = path
        self.ttl = ttl

    def _read(self) -> dict[str, dict]:
        if not self.path.exists():
            return {}
        try:
            return json.loads(self.path.read_text(encoding="utf-8"))
        except json.JSONDecodeError:
            return {}

    def _write(self, data: dict[str, dict]) -> None:
        self.path.parent.mkdir(parents=True, exist_ok=True)
        self.path.write_text(json.dumps(data, indent=2), encoding="utf-8")

    def _purge(self, data: dict[str, dict]) -> dict[str, dict]:
        now = time.time()
        return {k: v for k, v in data.items() if v["expires_at"] > now}

    def create(self, action: str, payload: dict[str, Any]) -> _Pending:
        pending = _Pending(token=secrets.token_urlsafe(24), action=action, payload=payload,
                            expires_at=time.time() + self.ttl)
        data = self._purge(self._read())
        data[pending.token] = asdict(pending)
        self._write(data)
        return pending

    def consume(self, token: str) -> _Pending | None:
        data = self._purge(self._read())
        raw = data.pop(token, None)
        self._write(data)
        return _Pending(**raw) if raw else None


confirmations = _ConfirmStore()


# ---------------------------------------------------------------------------
# Helpers de git e varredura
# ---------------------------------------------------------------------------

def _run(args: list[str], check: bool = True) -> str:
    result = subprocess.run(args, cwd=REPO_ROOT, capture_output=True, text=True)
    if check and result.returncode != 0:
        raise RuntimeError(f"comando falhou: {' '.join(args)}\n{result.stderr}")
    return result.stdout


def _is_ignored(path: str) -> bool:
    result = subprocess.run(["git", "check-ignore", "-q", path], cwd=REPO_ROOT, capture_output=True)
    return result.returncode == 0


def _iter_target_files(scope: str) -> list[Path]:
    if scope == "staged":
        out = _run(["git", "diff", "--cached", "--name-only"])
        paths = out.splitlines()
    elif scope == "all":
        tracked = _run(["git", "ls-files"]).splitlines()
        untracked = _run(["git", "ls-files", "--others", "--exclude-standard"]).splitlines()
        paths = tracked + untracked
    else:  # "tracked" (default) — o que realmente seria publicado
        paths = _run(["git", "ls-files"]).splitlines()
    return sorted({Path(p) for p in paths if p})


def _shannon_entropy(s: str) -> float:
    if not s:
        return 0.0
    counts = collections.Counter(s)
    length = len(s)
    return -sum((c / length) * math.log2(c / length) for c in counts.values())


def _ip_note(ip_str: str) -> str | None:
    try:
        ip = ipaddress.ip_address(ip_str)
    except ValueError:
        return None
    if ip.is_loopback or ip.is_link_local or ip.is_reserved or ip.is_multicast or ip.is_unspecified:
        return None
    doc_ranges = [ipaddress.ip_network(n) for n in ("192.0.2.0/24", "198.51.100.0/24", "203.0.113.0/24")]
    if any(ip in net for net in doc_ranges):
        return None  # faixa de documentação (RFC 5737) — placeholder seguro, não flagar
    if ip.is_private:
        return "ip privada/interna — confirme que não é topologia real antes de publicar"
    return "ip pública — pode identificar infraestrutura real, revise antes de publicar"


def _redact(value: str) -> str:
    if len(value) <= 8:
        return "*" * len(value)
    return f"{value[:4]}…{value[-4:]}"


def _scan_file(rel: Path) -> list[tuple[str, int, str, str, str]]:
    path = REPO_ROOT / rel
    if not path.is_file() or path.suffix.lower() in IMAGE_EXTENSIONS:
        return []
    try:
        if path.stat().st_size > MAX_SCAN_BYTES:
            return []
        text = path.read_text(encoding="utf-8")
    except (UnicodeDecodeError, OSError):
        return []

    findings: list[tuple[str, int, str, str, str]] = []
    for lineno, line in enumerate(text.splitlines(), start=1):
        for name, pattern, severity in SECRET_PATTERNS:
            for match in pattern.finditer(line):
                if name == "ip_address":
                    note = _ip_note(match.group(0))
                    if note is None:
                        continue
                    findings.append((str(rel), lineno, "ip_address", note, match.group(0)))
                    continue
                if name == "generic_secret_assignment":
                    value = match.group(2)
                    # descarta interpolação (f-string '{...}', shell '${...}'/'$VAR') — é código
                    # gerando/lendo um valor em runtime, não um segredo literal no arquivo
                    if "{" in value or "$" in value:
                        continue
                    findings.append((str(rel), lineno, name, severity, _redact(value)))
                    continue
                findings.append((str(rel), lineno, name, severity, _redact(match.group(0))))
        # heurística de entropia: só tokens "soltos" (sem '/' nem '=' no meio, que fariam o match
        # engolir caminhos inteiros ou pares KEY=value) com pelo menos 24 caracteres
        for token in re.findall(r"[A-Za-z0-9_-]{24,}", line):
            if not token.isdigit() and _shannon_entropy(token) >= 4.25:
                findings.append((str(rel), lineno, "alta_entropia", "media", _redact(token)))
    return findings


def _scan_high_confidence() -> list[str]:
    out = []
    for rel in _iter_target_files("tracked"):
        for r, lineno, name, _sev, _preview in _scan_file(rel):
            if name in HIGH_CONFIDENCE_NAMES:
                out.append(f"{r}:{lineno} — {name}")
    return out


# ---------------------------------------------------------------------------
# Tools
# ---------------------------------------------------------------------------

@mcp.tool()
def check_gitignore() -> str:
    """Verifica se secrets/, data/, .env e config/hosts.yaml estão de fato ignorados pelo git E
    que nenhum deles (nem arquivos com nome suspeito: chaves, .pem, credenciais) já está
    rastreado — adicionar algo ao .gitignore não desfaz um commit anterior."""
    tracked = set(_run(["git", "ls-files"]).splitlines())
    required_ok = True
    lines = ["Paths obrigatórios (devem estar ignorados E não rastreados):"]

    for req in REQUIRED_IGNORED_PATHS:
        display = req.rstrip("/")
        # 'dir/**' no .gitignore casa o CONTEÚDO do diretório, não o nome nu do diretório — testa
        # um arquivo hipotético dentro dele, que é o que de fato importa (dá pra 'git add' algo lá?)
        probe = f"{display}/.subot-guardian-probe" if req.endswith("/") else display
        ignored = _is_ignored(probe)
        tracked_hit = sorted(
            t for t in tracked
            if (t == display or t.startswith(display + "/")) and t not in ALLOWED_TRACKED_UNDER_REQUIRED
        )
        ok = ignored and not tracked_hit
        required_ok = required_ok and ok
        detail = ""
        if not ignored:
            detail += " (não está sendo ignorado — falta padrão em .gitignore)"
        if tracked_hit:
            detail += f" (JÁ RASTREADO: {tracked_hit[0]} — rode 'git rm --cached {tracked_hit[0]}' e commit)"
        lines.append(f"  [{'OK' if ok else 'FALHA'}] {req}{detail}")

    # Varredura de nomes suspeitos é ADVISORY — sinaliza pra revisão humana/do agente, mas não
    # bloqueia git_push sozinha (senão qualquer achado permanente e já aceito, como .env.example
    # ou o próprio secrets.py, travaria todo push para sempre).
    suspicious = sorted(t for t in tracked if any(p.search(t) for p in SUSPICIOUS_NAME_PATTERNS))
    lines.append("")
    lines.append("Varredura por nome suspeito entre arquivos já rastreados (revisão manual — não bloqueia push):")
    if suspicious:
        for s in suspicious:
            lines.append(f"  [REVISAR] {s}")
    else:
        lines.append("  nenhum nome suspeito encontrado")

    _audit("check_gitignore", "ok" if required_ok else "failure",
           {"required_ok": required_ok, "suspicious": suspicious})
    header = "OK (paths obrigatórios)" if required_ok else "FALHA — paths obrigatórios com problema, resolva antes de publicar"
    if suspicious:
        header += " | há achados de revisão manual (ver abaixo) — não bloqueiam push, mas confira"
    lines.insert(0, header)
    return "\n".join(lines)


@mcp.tool()
def scan_for_secrets(scope: str = "tracked") -> str:
    """Varre arquivos de texto em busca de segredos: chaves privadas, AWS keys, tokens Slack, JWT,
    atribuições tipo api_key=..., IPs (com nota de severidade) e strings de alta entropia
    (heurística). scope: 'tracked' (default, o que seria publicado), 'staged' ou 'all'."""
    files = _iter_target_files(scope)
    findings: list[tuple[str, int, str, str, str]] = []
    for rel in files:
        findings.extend(_scan_file(rel))

    _audit("scan_for_secrets", "findings" if findings else "clean", {"scope": scope, "count": len(findings)})

    if not findings:
        return f"nenhum achado em {len(files)} arquivo(s) (escopo: {scope})"

    lines = [f"{len(findings)} achado(s) em {len(files)} arquivo(s) (escopo: {scope}):"]
    for rel, lineno, name, severity, preview in findings:
        lines.append(f"  [{severity}] {rel}:{lineno} — {name} — {preview}")
    return "\n".join(lines)


@mcp.tool()
def scan_images_for_metadata(scope: str = "tracked") -> str:
    """Lista metadados (EXIF/GPS/autor/software) de imagens no escopo dado. NÃO analisa o
    conteúdo visual — se o agente que está chamando tiver visão (modelo multimodal), ele deve
    abrir cada imagem listada e inspecionar o conteúdo (texto na tela, credenciais visíveis,
    hostnames/IPs reais) antes de aprovar a publicação."""
    files = [f for f in _iter_target_files(scope) if (REPO_ROOT / f).suffix.lower() in IMAGE_EXTENSIONS]
    if not files:
        return f"nenhuma imagem encontrada (escopo: {scope})"

    try:
        from PIL import Image
        from PIL.ExifTags import TAGS
    except ImportError:
        return "Pillow não instalado (pip install Pillow) — não é possível ler metadados de imagem."

    lines = [f"{len(files)} imagem(ns) encontrada(s) (escopo: {scope}):"]
    any_metadata = False
    interesting_tags = {"GPSInfo", "Make", "Model", "Software", "DateTime", "Artist", "HostComputer", "OwnerName"}
    for rel in files:
        path = REPO_ROOT / rel
        try:
            img = Image.open(path)
            exif = img.getexif()
        except Exception as exc:  # noqa: BLE001
            lines.append(f"  [ERRO] {rel}: não foi possível abrir ({exc})")
            continue

        found = {}
        for tag_id, value in (exif or {}).items():
            tag = TAGS.get(tag_id, tag_id)
            if tag in interesting_tags:
                found[str(tag)] = str(value)[:80]
        for k, v in img.info.items():
            if k.lower() not in ("dpi",):
                found[f"info:{k}"] = str(v)[:80]

        if found:
            any_metadata = True
            lines.append(f"  [METADADOS] {rel}: {found}")
        else:
            lines.append(f"  [limpo] {rel}: sem metadados relevantes")

    lines.append("")
    lines.append("IMPORTANTE: isto só cobre metadados. O conteúdo visual de cada imagem listada "
                 "acima precisa de inspeção — visual (se o modelo tiver visão) ou humana.")

    _audit("scan_images_for_metadata", "findings" if any_metadata else "clean",
           {"scope": scope, "count": len(files), "with_metadata": any_metadata})
    return "\n".join(lines)


@mcp.tool()
def strip_image_metadata(path: str, apply: bool = False) -> str:
    """Remove metadados (EXIF/info) de uma imagem, regravando-a a partir só dos pixels.
    Dry-run por padrão (apply=False) — só mostra se há metadados; apply=True regrava o arquivo."""
    try:
        from PIL import Image
    except ImportError:
        return "Pillow não instalado (pip install Pillow) — não é possível processar imagens."

    full = REPO_ROOT / path
    if not full.is_file():
        return f"arquivo não encontrado: {path}"

    img = Image.open(full)
    had_metadata = bool(img.getexif()) or bool(img.info)
    if not had_metadata:
        return f"{path}: já não tem metadados a remover"
    if not apply:
        return f"{path}: tem metadados (EXIF/info). Chame de novo com apply=true para regravar sem eles."

    clean = Image.new(img.mode, img.size)
    clean.putdata(list(img.getdata()))
    clean.save(full)

    _audit("strip_image_metadata", "executed", {"path": path})
    return f"{path}: metadados removidos e imagem regravada"


@mcp.tool()
def git_status_summary() -> str:
    """Mostra branch atual, remotes configurados e 'git status --short'."""
    branch = _run(["git", "branch", "--show-current"]).strip() or "(HEAD destacado)"
    status = _run(["git", "status", "--short"]).strip() or "(working tree limpo)"
    remotes = _run(["git", "remote", "-v"]).strip() or "(nenhum remote configurado)"
    return f"branch atual: {branch}\n\nremotes:\n{remotes}\n\nstatus (--short):\n{status}"


@mcp.tool()
def git_remote_list() -> str:
    """Lista os remotes git configurados."""
    return _run(["git", "remote", "-v"]).strip() or "nenhum remote configurado"


@mcp.tool()
def git_set_remote(url: str, name: str = "origin", confirm_token: str | None = None) -> str:
    """Cria ou atualiza um remote git (ex.: apontar 'origin' para o repositório real no GitHub
    depois de criado). Sempre exige confirmação — chame uma vez para receber um confirm_token,
    depois de novo com os MESMOS argumentos mais esse token."""
    payload = {"name": name, "url": url}
    existing = _run(["git", "remote"]).split()

    if confirm_token:
        pending = confirmations.consume(confirm_token)
        if pending is None or pending.action != "git_set_remote" or pending.payload != payload:
            return "confirm_token inválido ou expirado — chame de novo sem confirm_token para reiniciar"
    else:
        pending = confirmations.create("git_set_remote", payload)
        _audit("git_set_remote", "confirmation_required", payload)
        verbo = "atualizar" if name in existing else "criar"
        return (f"CONFIRMAÇÃO NECESSÁRIA. Rode de novo com os mesmos argumentos mais "
                f"confirm_token='{pending.token}' para {verbo} o remote '{name}'.")

    if name in existing:
        _run(["git", "remote", "set-url", name, url])
        action = "atualizado"
    else:
        _run(["git", "remote", "add", name, url])
        action = "criado"

    _audit("git_set_remote", "executed", payload)
    return f"remote '{name}' {action}: {url}"


@mcp.tool()
def git_push(remote: str = "origin", branch: str | None = None, confirm_token: str | None = None) -> str:
    """Publica (git push) no remote. Roda check_gitignore e uma varredura de alta confiança por
    segredos ANTES de qualquer coisa — bloqueia incondicionalmente se algo crítico for encontrado
    (chave privada, AWS key, token Slack), mesmo com confirm_token. Se estiver limpo, ainda exige
    confirmação explícita (é uma publicação para um destino compartilhado)."""
    branch = branch or _run(["git", "branch", "--show-current"]).strip()
    if not branch:
        return "não foi possível determinar a branch atual (HEAD destacado?) — informe 'branch' explicitamente"

    hard_findings = _scan_high_confidence()
    if hard_findings:
        _audit("git_push", "blocked", {"remote": remote, "branch": branch, "findings": hard_findings})
        listed = "\n".join(f"  - {f}" for f in hard_findings)
        return f"BLOQUEADO — achados de alta confiança precisam ser resolvidos antes de qualquer push:\n{listed}"

    ignore_report = check_gitignore()
    if "FALHA" in ignore_report:
        _audit("git_push", "blocked", {"remote": remote, "branch": branch, "reason": "check_gitignore"})
        return f"BLOQUEADO — check_gitignore encontrou problemas nos paths obrigatórios, resolva antes de dar push:\n\n{ignore_report}"

    payload = {"remote": remote, "branch": branch}
    if confirm_token:
        pending = confirmations.consume(confirm_token)
        if pending is None or pending.action != "git_push" or pending.payload != payload:
            return "confirm_token inválido ou expirado — chame git_push de novo sem confirm_token para reiniciar"
    else:
        pending = confirmations.create("git_push", payload)
        _audit("git_push", "confirmation_required", payload)
        return (f"Higiene OK (sem achados de alta confiança, gitignore ok). CONFIRMAÇÃO NECESSÁRIA "
                f"para publicar. Rode de novo com confirm_token='{pending.token}' para dar push de "
                f"'{branch}' em '{remote}'.")

    result = subprocess.run(["git", "push", remote, branch], cwd=REPO_ROOT, capture_output=True, text=True)
    _audit("git_push", "executed" if result.returncode == 0 else "error",
           {"remote": remote, "branch": branch, "returncode": result.returncode})
    if result.returncode != 0:
        return f"ERRO no push: {result.stderr.strip()}"
    return f"push concluído: {branch} -> {remote}\n{(result.stdout + result.stderr).strip()}"


if __name__ == "__main__":
    mcp.run()
