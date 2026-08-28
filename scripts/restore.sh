#!/usr/bin/env bash
# Restaura um backup de ambiente gerado por scripts/backup.sh — o par exato do install.sh: clone
# a ferramenta do git, rode install.sh (ou scripts/setup.sh) numa VM nova, PARE a stack, e então
# restaure aqui por cima o backup da instância anterior antes de subir de novo.
#
# DESTRUTIVO: sobrescreve ./data, .env, config/hosts.yaml (e ./secrets, se presente no arquivo).
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

ARCHIVE="${1:?uso: restore.sh <backups/subot-env-backup-*.tar.gz>}"

echo "Isto vai SOBRESCREVER ./data, .env, config/hosts.yaml (e ./secrets, se presente no arquivo)."
echo "Pare a stack antes, se ainda não parou: docker compose down"
read -r -p "Digite 'yes' para continuar: " CONFIRM
[ "$CONFIRM" = "yes" ] || { echo "abortado"; exit 1; }

tar -xzf "$ARCHIVE"
echo "==> restaurado a partir de ${ARCHIVE}."
echo ""
echo "    LEMBRETE: a chave SSH restaurada em secrets/ssh/ está protegida por passphrase, e essa"
echo "    passphrase NÃO veio no backup. Exporte-a antes de subir a stack:"
echo "      export SUBOT_SSH_KEY_PASSPHRASE='<passphrase guardada externamente>'"
echo "      docker compose up -d"
echo "    Sem isso os containers sobem, mas toda operação SSH falha."
