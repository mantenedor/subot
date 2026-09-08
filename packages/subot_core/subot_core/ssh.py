"""Gateway SSH — o único lugar por onde comandos/arquivos alcançam um host gerenciado.

Comandos `safe` rodam direto. Comandos `sensitive`/`destructive` exigem um `reason` humano-legível
e passam por escalação de privilégio real: para `sensitive`, primeiro tenta o atalho de sudoers
pré-promovido (ver managed-host-gate/bin/apply-sudoers-policy.sh); se não estiver promovido nesse
host (ou for `destructive`, que nunca ganha o atalho), cai no fallback do managed-host-gate —
aprovação humana assíncrona via Telegram, em tempo real. Isso substitui o antigo `confirm_token`
autosservível (a própria IA gerava e consumia — ver docs/ARCHITECTURE.md) por controles reais.
`ssh_upload`/`ssh_download` continuam com `confirm_token` (`_gate`/`_transfer`) — é um risco
diferente (movimentação de arquivo), sem análogo de sudoers.

Toda chamada é sempre registrada em auditoria (sucesso, bloqueio, motivo pendente ou erro).
"""
from __future__ import annotations

import re
import shlex
from dataclasses import dataclass

import paramiko

from . import audit, secrets
from .confirm import ConfirmationStore, PendingAction
from .inventory import Host, Inventory
from .policy import Decision, PolicyEngine, Risk


@dataclass
class ExecResult:
    status: str  # "executed" | "confirmation_required" | "reason_required" | "blocked" | "error"
    exit_code: int | None = None
    stdout: str = ""
    stderr: str = ""
    confirm_token: str | None = None
    reason: str = ""
    via: str = ""  # "safe" | "sudo" | "gate" — só diagnóstico/auditoria, não é contrato de API


# Caracteres que permitem embutir um SEGUNDO comando shell dentro de uma string aprovada como
# 'sensitive' — fnmatch/glob (usado por policy.py e pelo próprio sudoers) não é ciente de shell,
# então "systemctl restart nginx" bate no padrão promovido mas "systemctl restart nginx; rm -rf ~"
# também bateria (o '*' do glob casa com qualquer coisa, incluindo ';'). O atalho de sudo nunca
# deve ser tentado nesse caso — a sonda só validaria o primeiro comando da linha, e o resto rodaria
# sem privilégio mas TAMBÉM sem qualquer aprovação humana. Cai no fallback do Gate em vez disso,
# onde um humano vê a string inteira antes de aprovar.
_UNSAFE_FOR_SUDO_SHORTCUT = re.compile(r"[;&|`\n]|\$\(")


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

    @staticmethod
    def _run(client: paramiko.SSHClient, command: str, timeout: int) -> tuple[int, str, str]:
        _, stdout, stderr = client.exec_command(command, timeout=timeout)
        exit_code = stdout.channel.recv_exit_status()
        out = stdout.read().decode(errors="replace")
        err = stderr.read().decode(errors="replace")
        return exit_code, out, err

    def _gate(self, action: str, payload: dict, risk: Risk, reason: str, actor: str,
              confirm_token: str | None) -> tuple[PendingAction | None, ExecResult | None]:
        """Verificação de confirmação por token — hoje só usada por `_transfer`
        (upload/download). `exec()` não usa mais isto (ver `_exec_privileged`). Retorna
        (pending_aprovado_ou_None, resultado_antecipado_ou_None); se resultado_antecipado não for
        None, o chamador deve retorná-lo imediatamente, sem executar nada."""
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

    def exec(self, host_name: str, command: str, *, actor: str, reason: str | None = None) -> ExecResult:
        host = self.inventory.get(host_name)
        decision: Decision = self.policy.classify(command, host_is_protected=host.is_protected)
        payload = {"host": host_name, "command": command}

        if decision.risk is Risk.BLOCKED:
            audit.record("ssh_exec", actor=actor, risk=decision.risk.value, status="blocked",
                         detail={**payload, "reason": decision.reason})
            return ExecResult(status="blocked", reason=decision.reason)

        if decision.risk is Risk.SAFE:
            try:
                client = self._connect(host)
                try:
                    exit_code, out, err = self._run(client, command, timeout=60)
                finally:
                    client.close()
            except Exception as exc:  # noqa: BLE001 - reporta ao chamador + audita, nunca engole em silêncio
                audit.record("ssh_exec", actor=actor, risk=decision.risk.value, status="error",
                             detail={**payload, "error": str(exc)})
                return ExecResult(status="error", reason=str(exc))
            audit.record("ssh_exec", actor=actor, risk=decision.risk.value, status="executed",
                         detail={**payload, "exit_code": exit_code})
            return ExecResult(status="executed", exit_code=exit_code, stdout=out, stderr=err, via="safe")

        # SENSITIVE ou DESTRUCTIVE: escalação de privilégio real. Exige um motivo humano-legível
        # antes de sequer tentar SSH — sem ele, nem toca a rede (substitui o antigo confirm_token
        # autosservível, que a própria IA gerava e consumia sozinha).
        if not reason:
            audit.record("ssh_exec", actor=actor, risk=decision.risk.value, status="reason_required",
                         detail=payload)
            return ExecResult(status="reason_required", reason=decision.reason)

        return self._exec_privileged(host, command, decision.risk, reason, actor, payload)

    def _exec_privileged(self, host: Host, command: str, risk: Risk, reason: str, actor: str,
                          payload: dict) -> ExecResult:
        """SENSITIVE tenta o atalho de sudoers pré-promovido (sonda `sudo -n -l`, separada da
        execução real, para nunca confundir "sudo negou" com "comando promovido falhou sozinho").
        DESTRUCTIVE nunca tenta sudo, mesmo que por engano esteja promovido no host — reforça em
        código a decisão de que destructive não ganha atalho. Em qualquer caso de fallback, cai no
        managed-host-gate (aprovação humana assíncrona via Telegram) pela mesma conexão SSH."""
        try:
            client = self._connect(host)
        except Exception as exc:  # noqa: BLE001
            audit.record("ssh_exec", actor=actor, risk=risk.value, status="error",
                         detail={**payload, "reason": reason, "error": str(exc)})
            return ExecResult(status="error", reason=str(exc))

        try:
            if risk is Risk.SENSITIVE and not _UNSAFE_FOR_SUDO_SHORTCUT.search(command):
                # 'sudo -n -l --' não executa nada, só reporta se o comando (com esses argumentos
                # exatos, tokenizados pelo shell remoto) está autorizado sem senha — daí ser uma
                # sonda separada da execução real logo abaixo, não o mesmo comando reaproveitado.
                probe_ec, _probe_out, _probe_err = self._run(client, f"sudo -n -l -- {command}", timeout=30)
                if probe_ec == 0:
                    exit_code, out, err = self._run(client, f"sudo -n -- {command}", timeout=60)
                    audit.record("ssh_exec", actor=actor, risk=risk.value, status="executed",
                                 detail={**payload, "reason": reason, "exit_code": exit_code, "via": "sudo"})
                    return ExecResult(status="executed", exit_code=exit_code, stdout=out, stderr=err, via="sudo")

            # Fallback: SENSITIVE não promovido no sudoers deste host, ou DESTRUCTIVE. 'command' e
            # 'reason' vão como dois argumentos shell opacos via shlex.quote (diferente da sonda
            # acima, que precisa dos tokens SEPARADOS para o matching do sudoers) —
            # subot-gate-request espera exatamente 2 argumentos posicionais, o comando inteiro
            # como uma string só. Path absoluto (não só o nome) porque client.exec_command roda
            # uma sessão SSH não-interativa/não-login — não fonte .bashrc/.profile, então PATH
            # pode não incluir /usr/local/bin dependendo da configuração do sshd/shell do host.
            gate_cmd = f"/usr/local/bin/subot-gate-request {shlex.quote(command)} {shlex.quote(reason)}"
            exit_code, out, err = self._run(client, gate_cmd, timeout=350)
            audit.record("ssh_exec", actor=actor, risk=risk.value, status="executed",
                         detail={**payload, "reason": reason, "exit_code": exit_code, "via": "gate"})
            return ExecResult(status="executed", exit_code=exit_code, stdout=out, stderr=err, via="gate")
        except Exception as exc:  # noqa: BLE001
            audit.record("ssh_exec", actor=actor, risk=risk.value, status="error",
                         detail={**payload, "reason": reason, "error": str(exc)})
            return ExecResult(status="error", reason=str(exc))
        finally:
            client.close()

    def propose_sudoers_policy(self, host_name: str, payload_b64: str, *, reason: str,
                               actor: str) -> ExecResult:
        """Aplica managed-host-gate/bin/apply-sudoers-policy.sh no host, via 'subot identity sync'
        (CLI do orquestrador). SEMPRE tratado como DESTRUCTIVE — nunca passa por policy.classify()
        nem pode ganhar o atalho de sudoers ele mesmo, mesmo que por engano um dia esteja
        'promovido' num manifesto (o payload muda a cada chamada, então nunca bateria com uma
        regra sudoers estática de qualquer forma — mas fixar DESTRUCTIVE aqui é defesa em
        profundidade em código, não incidental). Sempre exige aprovação humana via Gate."""
        host = self.inventory.get(host_name)
        command = f"/opt/subot-gate/bin/apply-sudoers-policy.sh {shlex.quote(payload_b64)}"
        payload = {"host": host_name, "command": command}
        return self._exec_privileged(host, command, Risk.DESTRUCTIVE, reason, actor, payload)

    def show_sudoers(self, host_name: str, *, actor: str) -> ExecResult:
        """Lista o que já está de fato promovido no sudoers do host (`sudo -n -l`) — leitura pura,
        não muda nada, não passa por policy.classify()/Gate (mesmo espírito de um comando safe,
        mas não convém poluir allowlist.yaml com este detalhe de implementação)."""
        host = self.inventory.get(host_name)
        payload = {"host": host_name, "command": "sudo -n -l"}
        try:
            client = self._connect(host)
            try:
                exit_code, out, err = self._run(client, "sudo -n -l", timeout=30)
            finally:
                client.close()
        except Exception as exc:  # noqa: BLE001
            audit.record("identity_show", actor=actor, risk="safe", status="error",
                         detail={**payload, "error": str(exc)})
            return ExecResult(status="error", reason=str(exc))
        audit.record("identity_show", actor=actor, risk="safe", status="executed",
                     detail={**payload, "exit_code": exit_code})
        return ExecResult(status="executed", exit_code=exit_code, stdout=out, stderr=err, via="safe")

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
