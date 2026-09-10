#!/usr/bin/env bash
# Reinstala/atualiza o gate baixando a versão mais recente de gate/install.sh direto do GitHub,
# sem precisar de um checkout local do repo neste host. Pensado para hosts fora do inventário do
# subot (ex.: um host de backup dedicado, acessado via SSH root direto) — copie este arquivo pra
# lá e rode como root:
#
#   sudo bash reinstall-from-github.sh
#
# O que ele faz: baixa gate/install.sh (ref abaixo) para /tmp/subot-gate-install.sh e o executa.
# install.sh por sua vez baixa os demais arquivos do gate (install-gate.sh, bin/*, etc/*, systemd/*)
# para um diretório temporário próprio e roda install-gate.sh, que é idempotente — reaplicar não
# duplica usuário/chaves/sudoers/serviço já existentes, só atualiza o que mudou.
#
# Variáveis de ambiente aceitas (repassadas para install.sh/install-gate.sh sem alteração):
#   SUBOT_REPO_RAW_BASE           default: https://raw.githubusercontent.com/mantenedor/subot
#   SUBOT_REPO_REF                branch/tag, default: main
#   SUBOT_IDENTITY_JSON_B64       manifesto de identidade (ver ia/policy/managed-identity.json.example)
#   SUBOT_HOST_IDENTITY_JSON_B64  complemento específico deste host, se existir
#   SUBOT_BASTION_PUBKEY          chave pública do bastião (formato antigo, fallback)
#   SUBOT_GATE_ASSUME_YES         1 = não pede confirmação em nenhum passo do install-gate.sh
set -euo pipefail

REPO_RAW_BASE="${SUBOT_REPO_RAW_BASE:-https://raw.githubusercontent.com/mantenedor/subot}"
REPO_REF="${SUBOT_REPO_REF:-main}"
DEST=/tmp/subot-gate-install.sh

if [ "$(id -u)" -ne 0 ]; then
    echo "rode como root: sudo bash $0" >&2
    exit 1
fi

echo "==> baixando a versão mais recente de gate/install.sh (ref: ${REPO_REF}) para ${DEST}"
curl -fsSL "${REPO_RAW_BASE}/${REPO_REF}/gate/install.sh" -o "$DEST"
chmod +x "$DEST"

echo "==> executando ${DEST} (ele mesmo baixa os demais arquivos do gate e reinstala)"
exec bash "$DEST"
