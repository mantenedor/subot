"""Gateway SSH — o único lugar por onde comandos/arquivos alcançam um host gerenciado.

Toda chamada passa pela classificação de política e pelo protocolo de confirmação de duas etapas
antes de tocar a rede, e é sempre registrada em auditoria (sucesso, bloqueio ou erro).
"""
from __future__ import annotations

from dataclasses import dataclass

import paramiko

from . import audit, secrets
from .confirm import ConfirmationStore, PendingAction
from .inventory import Host, Inventory
from .policy import Decision, PolicyEngine, Risk


@dataclass
class ExecResult:
    status: str  # "executed" | "confirmation_required" | "blocked" | "error"
    exit_code: int | None = None
    stdout: str = ""
    stderr: str = ""
    confirm_token: str | None = None
    reason: str = ""


class SSHGateway:
    def __init__(self, inventory: Inventory | None = None, policy: PolicyEngine | None = None,
                 confirmations: ConfirmationStore | None = None):
        self.inventory = inventory or Inventory()
        self.policy = policy or PolicyEngine()
        self.confirmations = confirmations or ConfirmationStore()

    def _connect(self, host: Host) -> paramiko.SSHClient:
        client = paramiko.SSHClient()
        client.load_host_keys(str(secrets.known_hosts_path()))
        # Nunca aceita automaticamente uma host key desconhecida (sem TOFU silencioso).
        client.set_missing_host_key_policy(paramiko.RejectPolicy())
        key_path = secrets.default_identity(host.identity_file)
        client.connect(
            hostname=host.address,
            port=host.port,
            username=host.user,
            key_filename=str(key_path),
            passphrase=secrets.key_passphrase(),
            timeout=15,
            allow_agent=False,
            look_for_keys=False,
        )
        return client

    def _gate(self, action: str, payload: dict, risk: Risk, reason: str, actor: str,
              confirm_token: str | None) -> tuple[PendingAction | None, ExecResult | None]:
        """Verificação de confirmação compartilhada. Retorna (pending_aprovado_ou_None,
        resultado_antecipado_ou_None). Se resultado_antecipado não for None, o chamador deve
        retorná-lo imediatamente, sem executar nada."""
        if risk is Risk.BLOCKED:
            audit.record(action, actor=actor, risk=risk.value, status="blocked", detail={**payload, "reason": reason})
            return None, ExecResult(status="blocked", reason=reason)

        if risk is Risk.SAFE:
            return None, None

        if confirm_token:
            pending = self.confirmations.consume(confirm_token)
            if pending is None or pending.action != action or pending.payload != payload:
                audit.record(action, actor=actor, risk=risk.value, status="confirmation_invalid", detail=payload)
                return None, ExecResult(status="confirmation_required", reason="confirm_token inválido ou expirado")
            return pending, None

        pending = self.confirmations.create(action, payload, risk.value, reason, actor)
        audit.record(action, actor=actor, risk=risk.value, status="confirmation_required",
                     detail={**payload, "reason": reason})
        return None, ExecResult(status="confirmation_required", confirm_token=pending.token, reason=reason)

    def exec(self, host_name: str, command: str, *, actor: str, confirm_token: str | None = None) -> ExecResult:
        host = self.inventory.get(host_name)
        decision: Decision = self.policy.classify(command, host_is_protected=host.is_protected)
        payload = {"host": host_name, "command": command}
        _, early = self._gate("ssh_exec", payload, decision.risk, decision.reason, actor, confirm_token)
        if early:
            return early

        try:
            client = self._connect(host)
            try:
                _, stdout, stderr = client.exec_command(command, timeout=60)
                exit_code = stdout.channel.recv_exit_status()
                out = stdout.read().decode(errors="replace")
                err = stderr.read().decode(errors="replace")
            finally:
                client.close()
        except Exception as exc:  # noqa: BLE001 - reporta ao chamador + audita, nunca engole em silêncio
            audit.record("ssh_exec", actor=actor, risk=decision.risk.value, status="error",
                         detail={**payload, "error": str(exc)})
            return ExecResult(status="error", reason=str(exc))

        audit.record("ssh_exec", actor=actor, risk=decision.risk.value, status="executed",
                     detail={**payload, "exit_code": exit_code})
        return ExecResult(status="executed", exit_code=exit_code, stdout=out, stderr=err)

    def _transfer(self, action: str, host_name: str, local_path: str, remote_path: str, *,
                  actor: str, confirm_token: str | None, direction: str) -> ExecResult:
        host = self.inventory.get(host_name)
        payload = {"host": host_name, "local": local_path, "remote": remote_path}
        # Transferência de arquivo é sempre no mínimo 'sensitive' — nunca roda sem confirmação.
        risk = Risk.DESTRUCTIVE if host.is_protected else Risk.SENSITIVE
        reason = f"{direction} de arquivo sempre exige confirmação" + (" (host protected/prod)" if host.is_protected else "")
        _, early = self._gate(action, payload, risk, reason, actor, confirm_token)
        if early:
            return early

        try:
            client = self._connect(host)
            try:
                sftp = client.open_sftp()
                try:
                    if direction == "upload":
                        sftp.put(local_path, remote_path)
                    else:
                        sftp.get(remote_path, local_path)
                finally:
                    sftp.close()
            finally:
                client.close()
        except Exception as exc:  # noqa: BLE001
            audit.record(action, actor=actor, risk=risk.value, status="error", detail={**payload, "error": str(exc)})
            return ExecResult(status="error", reason=str(exc))

        audit.record(action, actor=actor, risk=risk.value, status="executed", detail=payload)
        return ExecResult(status="executed", stdout=f"{direction} ok: {local_path} <-> {host_name}:{remote_path}")

    def upload(self, host_name: str, local_path: str, remote_path: str, *, actor: str,
               confirm_token: str | None = None) -> ExecResult:
        return self._transfer("ssh_upload", host_name, local_path, remote_path,
                              actor=actor, confirm_token=confirm_token, direction="upload")

    def download(self, host_name: str, remote_path: str, local_path: str, *, actor: str,
                 confirm_token: str | None = None) -> ExecResult:
        return self._transfer("ssh_download", host_name, local_path, remote_path,
                              actor=actor, confirm_token=confirm_token, direction="download")
