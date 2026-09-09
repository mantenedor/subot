from __future__ import annotations

import pytest

from subot_core import audit
from subot_core.confirm import ConfirmationStore
from subot_core.inventory import Inventory
from subot_core.policy import PolicyEngine, Risk
from subot_core.ssh import SSHGateway


@pytest.fixture(autouse=True)
def _isolate_audit(tmp_path, monkeypatch):
    # audit.record() nunca deve levantar, mas sem isto tentaria escrever em /opt/subot/data/audit
    # (inexistente/sem permissão neste ambiente de teste) a cada chamada.
    monkeypatch.setattr(audit, "AUDIT_DIR", tmp_path / "audit")


def _inventory(tmp_path, *, protected: bool = False) -> Inventory:
    domain_dir = tmp_path / "domain"
    host_dir = domain_dir / "on-prem" / "testhost"
    host_dir.mkdir(parents=True)
    tags = "[protected]" if protected else "[]"
    (host_dir / "host.yaml").write_text(
        f"address: 10.0.0.5\nuser: subot\ntags: {tags}\n",
        encoding="utf-8",
    )
    return Inventory(path=domain_dir)


def _policy(tmp_path) -> PolicyEngine:
    allowlist = tmp_path / "allowlist.yaml"
    allowlist.write_text(
        "safe_patterns:\n  - \"whoami\"\n"
        "sensitive_patterns:\n  - \"systemctl restart *\"\n",
        encoding="utf-8",
    )
    destructive = tmp_path / "destructive.yaml"
    destructive.write_text(
        "destructive_patterns:\n  - \"systemctl stop *\"\n"
        "blocked_patterns:\n  - \"rm -rf /\"\n",
        encoding="utf-8",
    )
    return PolicyEngine(allowlist_path=allowlist, destructive_path=destructive)


class FakeStream:
    def __init__(self, data: bytes = b""):
        self._data = data

    def read(self):
        return self._data


class FakeChannel:
    def __init__(self, exit_status: int):
        self._exit_status = exit_status

    def recv_exit_status(self):
        return self._exit_status


class FakeStdout(FakeStream):
    def __init__(self, data: bytes, exit_status: int):
        super().__init__(data)
        self.channel = FakeChannel(exit_status)


class FakeSSHClient:
    """Substitui paramiko.SSHClient — 'script' é a fila de respostas
    (exit_code, stdout_bytes, stderr_bytes) na ordem exata em que exec_command é chamado."""

    def __init__(self, script: list[tuple[int, bytes, bytes]]):
        self._script = list(script)
        self.calls: list[str] = []
        self.closed = False

    def exec_command(self, command: str, timeout: int | None = None):
        self.calls.append(command)
        assert self._script, f"chamada inesperada (sem script restante): {command!r}"
        exit_code, out, err = self._script.pop(0)
        return None, FakeStdout(out, exit_code), FakeStream(err)

    def close(self):
        self.closed = True


def _gateway(tmp_path, *, protected: bool = False, script: list[tuple[int, bytes, bytes]] | None = None):
    gateway = SSHGateway(
        inventory=_inventory(tmp_path, protected=protected),
        policy=_policy(tmp_path),
        confirmations=ConfirmationStore(path=tmp_path / "confirm_tokens.json"),
    )
    fake_client = FakeSSHClient(script or [])
    gateway._connect = lambda host: fake_client  # type: ignore[method-assign]
    return gateway, fake_client


def test_safe_command_runs_direct_without_reason(tmp_path):
    gateway, client = _gateway(tmp_path, script=[(0, b"subot\n", b"")])
    result = gateway.exec("testhost", "whoami", actor="test")
    assert result.status == "executed"
    assert result.exit_code == 0
    assert result.stdout == "subot\n"
    assert result.via == "safe"
    assert client.calls == ["whoami"]


def test_blocked_command_never_touches_ssh(tmp_path):
    gateway, client = _gateway(tmp_path, script=[])
    result = gateway.exec("testhost", "rm -rf /", actor="test")
    assert result.status == "blocked"
    assert client.calls == []


def test_sensitive_without_reason_returns_reason_required_and_never_touches_ssh(tmp_path):
    gateway, client = _gateway(tmp_path, script=[])
    result = gateway.exec("testhost", "systemctl restart nginx", actor="test")
    assert result.status == "reason_required"
    assert client.calls == []


def test_sensitive_promoted_in_sudoers_runs_via_sudo_without_gate(tmp_path):
    # sonda 'sudo -n -l' aprova (exit 0), depois a execução real também sucede.
    gateway, client = _gateway(tmp_path, script=[
        (0, b"", b""),                       # sudo -n -l -- systemctl restart nginx
        (0, b"restarted ok\n", b""),          # sudo -n -- systemctl restart nginx
    ])
    result = gateway.exec("testhost", "systemctl restart nginx", actor="test", reason="deploy")
    assert result.status == "executed"
    assert result.exit_code == 0
    assert result.stdout == "restarted ok\n"
    assert result.via == "sudo"
    assert len(client.calls) == 2
    assert client.calls[0] == "sudo -n -l -- systemctl restart nginx"
    assert client.calls[1] == "sudo -n -- systemctl restart nginx"


def test_sensitive_promoted_but_command_itself_fails_still_via_sudo(tmp_path):
    # sonda aprova, mas o comando promovido falha sozinho (exit_code != 0) — não deve ser
    # confundido com negação de sudo, nem cair no fallback do Gate.
    gateway, client = _gateway(tmp_path, script=[
        (0, b"", b""),                              # sonda aprova
        (3, b"", b"Unit nginx.service not found\n"),  # comando real falha
    ])
    result = gateway.exec("testhost", "systemctl restart nginx", actor="test", reason="deploy")
    assert result.status == "executed"
    assert result.exit_code == 3
    assert result.via == "sudo"
    assert len(client.calls) == 2  # nunca chegou a chamar subot-gate-request


def test_sensitive_with_shell_metacharacter_skips_sudo_shortcut_entirely(tmp_path):
    # "systemctl restart nginx; rm -rf ~" bate no glob 'systemctl restart *' (fnmatch não entende
    # shell) e classifica como SENSITIVE — mas por conter ';' nunca deve nem tentar a sonda sudo,
    # senão o segundo comando rodaria sem privilégio E sem qualquer aprovação humana. Só UMA
    # resposta na fila: se o código tentasse a sonda primeiro, o teste falharia por "chamada
    # inesperada".
    gateway, client = _gateway(tmp_path, script=[
        (0, b"", b""),  # única chamada esperada: subot-gate-request direto
    ])
    result = gateway.exec("testhost", "systemctl restart nginx; rm -rf ~", actor="test", reason="motivo")
    assert result.status == "executed"
    assert result.via == "gate"
    assert len(client.calls) == 1
    assert "subot-gate-request" in client.calls[0]


@pytest.mark.parametrize("shell_metachar_command", [
    "systemctl restart nginx && rm -rf ~",
    "systemctl restart nginx || rm -rf ~",
    "systemctl restart nginx | tee /etc/passwd",
    "systemctl restart `whoami`",
    "systemctl restart $(whoami)",
    "systemctl restart nginx\nrm -rf ~",
])
def test_sensitive_with_various_shell_metacharacters_skips_sudo_shortcut(tmp_path, shell_metachar_command):
    gateway, client = _gateway(tmp_path, script=[(0, b"", b"")])
    result = gateway.exec("testhost", shell_metachar_command, actor="test", reason="motivo")
    assert result.via == "gate"
    assert len(client.calls) == 1


def test_sensitive_not_promoted_falls_back_to_gate_approved(tmp_path):
    gateway, client = _gateway(tmp_path, script=[
        (1, b"", b"sudo: a password is required\n"),  # sonda nega
        (0, b"gate approved output\n", b""),           # subot-gate-request aprovado
    ])
    result = gateway.exec("testhost", "systemctl restart nginx", actor="test", reason="deploy urgente")
    assert result.status == "executed"
    assert result.exit_code == 0
    assert result.via == "gate"
    assert len(client.calls) == 2
    assert client.calls[0] == "sudo -n -l -- systemctl restart nginx"
    assert "subot-gate-request" in client.calls[1]
    assert "systemctl restart nginx" in client.calls[1]
    assert "deploy urgente" in client.calls[1]


def test_sensitive_not_promoted_falls_back_to_gate_denied(tmp_path):
    gateway, client = _gateway(tmp_path, script=[
        (1, b"", b"sudo: a password is required\n"),
        (10, b"", b"subot-gate: negado por humano (request_id=abc).\n"),
    ])
    result = gateway.exec("testhost", "systemctl restart nginx", actor="test", reason="motivo qualquer")
    assert result.status == "executed"  # o wrapper rodou; o exit_code é que sinaliza negação
    assert result.exit_code == 10
    assert result.via == "gate"


def test_sensitive_not_promoted_falls_back_to_gate_timeout(tmp_path):
    gateway, client = _gateway(tmp_path, script=[
        (1, b"", b"sudo: a password is required\n"),
        (11, b"", b"subot-gate: sem decisao humana dentro do prazo.\n"),
    ])
    result = gateway.exec("testhost", "systemctl restart nginx", actor="test", reason="motivo qualquer")
    assert result.exit_code == 11
    assert result.via == "gate"


def test_destructive_never_tries_sudo_even_if_hypothetically_promoted(tmp_path):
    # Só UMA resposta na fila: se o código tentasse a sonda sudo primeiro, o teste falharia por
    # 'chamada inesperada' na segunda tentativa de exec_command.
    gateway, client = _gateway(tmp_path, script=[
        (0, b"stopped\n", b""),  # única chamada esperada: subot-gate-request direto
    ])
    result = gateway.exec("testhost", "systemctl stop nginx", actor="test", reason="manutenção")
    assert result.status == "executed"
    assert result.via == "gate"
    assert len(client.calls) == 1
    assert "subot-gate-request" in client.calls[0]
    assert "sudo" not in client.calls[0]


def test_destructive_without_reason_returns_reason_required(tmp_path):
    gateway, client = _gateway(tmp_path, script=[])
    result = gateway.exec("testhost", "systemctl stop nginx", actor="test")
    assert result.status == "reason_required"
    assert client.calls == []


def test_protected_host_escalates_safe_pattern_to_sensitive(tmp_path):
    gateway, client = _gateway(tmp_path, protected=True, script=[])
    result = gateway.exec("testhost", "whoami", actor="test")
    assert result.status == "reason_required"
    assert client.calls == []


def test_propose_sudoers_policy_always_destructive_never_tries_sudo(tmp_path):
    gateway, client = _gateway(tmp_path, script=[
        (0, b"applied\n", b""),
    ])
    result = gateway.propose_sudoers_policy("testhost", "ZmFrZS1wYXlsb2Fk", reason="promover X", actor="test")
    assert result.status == "executed"
    assert result.via == "gate"
    assert len(client.calls) == 1
    assert "apply-sudoers-policy.sh" in client.calls[0]


def test_show_sudoers_reads_without_gate_or_policy(tmp_path):
    gateway, client = _gateway(tmp_path, script=[(0, b"(subot) NOPASSWD: /usr/bin/systemctl restart *\n", b"")])
    result = gateway.show_sudoers("testhost", actor="test")
    assert result.status == "executed"
    assert "systemctl" in result.stdout
    assert client.calls == ["sudo -n -l"]
