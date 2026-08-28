#!/bin/sh
set -eu

echo "[subot-agent] iniciando..."

SSH_DIR="${SUBOT_SSH_DIR:-/opt/subot/secrets/ssh}"
mkdir -p "$SSH_DIR" "${SUBOT_AUDIT_DIR:-/opt/subot/data/audit}"
touch "$SSH_DIR/known_hosts"

if [ -f "$SSH_DIR/bastion_id_ed25519" ]; then
    perm=$(stat -c "%a" "$SSH_DIR/bastion_id_ed25519" 2>/dev/null || echo "600")
    case "$perm" in
        600|400) ;;
        *) echo "[subot-agent] AVISO: $SSH_DIR/bastion_id_ed25519 tem permissao $perm (esperado 600). Rode 'chmod 600' no host." ;;
    esac
else
    echo "[subot-agent] AVISO: nenhuma chave do bastiao em $SSH_DIR/bastion_id_ed25519 — rode scripts/setup.sh no host primeiro."
fi

echo "[subot-agent] pronto. Servidores MCP registrados em .claude/settings.json; CLI do orquestrador disponivel como 'subot'."
exec "$@"
