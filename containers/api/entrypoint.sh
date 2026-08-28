#!/bin/sh
set -eu

echo "[subot-api] iniciando..."
SSH_DIR="${SUBOT_SSH_DIR:-/opt/subot/secrets/ssh}"
mkdir -p "${SUBOT_AUDIT_DIR:-/opt/subot/data/audit}"
touch "$SSH_DIR/known_hosts" 2>/dev/null || true

if [ -f "$SSH_DIR/bastion_id_ed25519" ] && ! ssh-keygen -y -P '' -f "$SSH_DIR/bastion_id_ed25519" >/dev/null 2>&1; then
    if [ -z "${SUBOT_SSH_KEY_PASSPHRASE:-}" ]; then
        echo "[subot-api] AVISO: a chave do bastiao esta protegida por passphrase mas SUBOT_SSH_KEY_PASSPHRASE nao foi definida — operacoes SSH vao falhar ate voce exportar essa variavel e subir a stack de novo."
    fi
fi

exec "$@"
