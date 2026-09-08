#!/usr/bin/env bash
# Gera um NOVO par de chaves SSH do bastião ao lado do atual (nunca apaga o antigo
# automaticamente — faça isso manualmente só depois de confirmar que todo host gerenciado aceita
# a nova chave).
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

STAMP="$(date -u +%Y%m%d)"
NEW_KEY="secrets/ssh/bastion_id_ed25519_${STAMP}"

if [ -f "$NEW_KEY" ]; then
    echo "já existe uma chave gerada hoje em ${NEW_KEY}, abortando"
    exit 1
fi

NEW_PASSPHRASE="$(openssl rand -base64 24 | tr -d '=+/')"
ssh-keygen -t ed25519 -f "$NEW_KEY" -N "$NEW_PASSPHRASE" -C "subot-bastion-${STAMP}"
chmod 600 "$NEW_KEY"
chmod 644 "${NEW_KEY}.pub"
# se rodar como root no host (dono fica root:root) e o binário existir, concede leitura pro UID
# 1000 (container 'agent') via ACL, sem abrir grupo/outros. Se secrets/ssh já pertence ao próprio
# UID 1000 (rotação rodando de dentro do container) isso é redundante — pula sem quebrar o script.
if command -v setfacl >/dev/null 2>&1; then
    setfacl -m u:1000:r "$NEW_KEY" || true
fi

echo ""
echo "    #################################################################"
echo "    # GUARDE ESTA PASSPHRASE AGORA — ela NÃO é salva em nenhum arquivo."
echo "    #"
echo "    #   ${NEW_PASSPHRASE}"
echo "    #################################################################"
echo ""
echo "==> nova chave gerada em ${NEW_KEY}"
echo "    1. envie ${NEW_KEY}.pub para o authorized_keys de cada host gerenciado"
echo "    2. valide o acesso com a nova chave em todos os hosts (com"
echo "       SUBOT_SSH_KEY_PASSPHRASE apontando pra passphrase acima)"
echo "    3. só então: rm secrets/ssh/bastion_id_ed25519* (par antigo) e"
echo "       mv ${NEW_KEY} secrets/ssh/bastion_id_ed25519 (+ .pub) para torná-la a padrão —"
echo "       depois exporte SUBOT_SSH_KEY_PASSPHRASE com a nova passphrase antes do próximo"
echo "       'docker compose up'"
