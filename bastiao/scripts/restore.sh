#!/usr/bin/env bash
# Restaura um backup de ambiente gerado por scripts/backup.sh — o par exato do install.sh: clone
# a ferramenta do git, rode install.sh (ou scripts/setup.sh) numa VM nova, PARE a stack, e então
# restaure aqui por cima o backup da instância anterior antes de subir de novo.
#
# DESTRUTIVO: sobrescreve ./data, ./config/hosts.yaml, ./bastiao/.env (e ./bastiao/secrets, se
# presente no arquivo) — extrai relativo à raiz do repo, mesma raiz usada por scripts/backup.sh.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../.."

ARCHIVE="${1:?uso: restore.sh <backups/subot-env-backup-*.tar.gz>}"

echo "Isto vai SOBRESCREVER ./data, ./bastiao/.env, ./config/hosts.yaml (e ./bastiao/secrets, se presente no arquivo)."
echo "Pare a stack antes, se ainda não parou: (cd bastiao && docker compose down)"
read -r -p "Digite 'yes' para continuar: " CONFIRM
[ "$CONFIRM" = "yes" ] || { echo "abortado"; exit 1; }

tar -xzf "$ARCHIVE"
echo "==> restaurado a partir de ${ARCHIVE}."
echo ""
echo "    LEMBRETE: a chave SSH restaurada em bastiao/secrets/ssh/ está protegida por passphrase, e essa"
echo "    passphrase NÃO veio no backup (redigida de propósito em scripts/backup.sh — nunca fica"
echo "    no mesmo arquivo que a chave). Preencha antes de subir a stack, ou preenchendo"
echo "    SUBOT_SSH_KEY_PASSPHRASE=<passphrase guardada externamente> no bastiao/.env restaurado, ou:"
echo "      export SUBOT_SSH_KEY_PASSPHRASE='<passphrase guardada externamente>'"
echo "      (cd bastiao && docker compose up -d)"
echo "    Sem isso os containers sobem, mas toda operação SSH falha."
