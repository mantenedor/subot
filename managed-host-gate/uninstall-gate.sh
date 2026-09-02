#!/usr/bin/env bash
# Reverte install-gate.sh — útil para QA/decommission. NÃO recria 'subotsu'/sudoers antigos (essa
# decisão é manual, deliberadamente, para não reabrir um caminho de escalação sem revisão humana).
set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
    echo "rode como root: sudo ./uninstall-gate.sh" >&2
    exit 1
fi

echo "==> parando e desabilitando o serviço"
systemctl stop subot-gate.service 2>/dev/null || true
systemctl disable subot-gate.service 2>/dev/null || true
rm -f /etc/systemd/system/subot-gate.service
systemctl daemon-reload

echo "==> removendo binários e estado (mantém nada — inclusive telegram.env e a auditoria!)"
read -r -p "isso apaga /opt/subot-gate inteiro, incluindo a auditoria local (gate-audit.jsonl). confirma? [y/N] " ans
if [ "${ans:-N}" = "y" ] || [ "${ans:-N}" = "Y" ]; then
    rm -rf /opt/subot-gate
    rm -f /usr/local/bin/subot-gate-request
    gpasswd -d subot subot-gate 2>/dev/null || true
    groupdel subot-gate 2>/dev/null || true
    echo "==> removido."
else
    echo "==> mantido /opt/subot-gate (só o serviço systemd foi desativado)."
fi
