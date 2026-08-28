#!/usr/bin/env bash
# Instalador de um comando só do subot, para uma VM nova:
#
#   curl -fsSL https://raw.githubusercontent.com/mantenedor/subot/main/install.sh | bash
#
# Repositório PRIVADO: a linha acima só funciona se o repo virar público. Enquanto for privado,
# busque este arquivo via 'gh api repos/mantenedor/subot/contents/install.sh --jq .download_url'
# (link raw com token temporário) e exporte SUBOT_REPO_URL com um token de escopo 'repo' embutido
# (https://x-access-token:<TOKEN>@github.com/mantenedor/subot.git) antes de rodar — ver README.
#
# Idempotente: se o diretório de destino já for um clone do subot, faz 'git pull' em vez de
# clonar de novo. Nunca sobrescreve .env / secrets/ / config/hosts.yaml existentes —
# scripts/setup.sh já preserva tudo isso.
#
# Variáveis de ambiente que ajustam o comportamento (opcional):
#   SUBOT_REPO_URL   URL do repositório git (default: aponte para o seu fork/org antes de publicar)
#   SUBOT_REPO_REF   branch/tag a clonar (default: main)
#   SUBOT_INSTALL_DIR diretório de destino (default: $HOME/subot)
set -euo pipefail

REPO_URL="${SUBOT_REPO_URL:-https://github.com/mantenedor/subot.git}"
REPO_REF="${SUBOT_REPO_REF:-main}"
INSTALL_DIR="${SUBOT_INSTALL_DIR:-$HOME/subot}"

log() { printf '==> %s\n' "$1"; }
require_cmd() { command -v "$1" >/dev/null 2>&1; }

log "verificando pré-requisitos"
if ! require_cmd git; then
    echo "git não encontrado. Instale git e rode este script de novo." >&2
    exit 1
fi

if ! require_cmd docker; then
    log "docker não encontrado — instalando via get.docker.com (script oficial da Docker Inc.)"
    curl -fsSL https://get.docker.com | sh
    if ! require_cmd docker; then
        echo "falha ao instalar o Docker automaticamente. Instale manualmente:" >&2
        echo "https://docs.docker.com/engine/install/" >&2
        exit 1
    fi
    if [ "$(id -u)" -ne 0 ] && require_cmd sudo; then
        sudo usermod -aG docker "$(whoami)" || true
        echo "    adicionado ao grupo 'docker' — pode ser necessário sair e logar de novo (ou 'newgrp docker')."
    fi
fi

if ! docker compose version >/dev/null 2>&1; then
    echo "plugin 'docker compose' (v2) não encontrado. Instalações recentes via get.docker.com já" >&2
    echo "trazem o docker-compose-plugin; se instalou o Docker de outra forma, adicione o plugin" >&2
    echo "manualmente: https://docs.docker.com/compose/install/" >&2
    exit 1
fi

if [ -d "$INSTALL_DIR/.git" ]; then
    log "diretório existente em $INSTALL_DIR — atualizando (git pull)"
    git -C "$INSTALL_DIR" pull --ff-only
else
    log "clonando $REPO_URL (ref: $REPO_REF) em $INSTALL_DIR"
    git clone --branch "$REPO_REF" --depth 1 "$REPO_URL" "$INSTALL_DIR"
fi

cd "$INSTALL_DIR"

log "rodando scripts/setup.sh (gera .env, hosts.yaml, chaves SSH, credenciais — nunca sobrescreve o que já existe)"
echo "    ATENÇÃO: se este for o primeiro setup, uma passphrase da chave SSH vai aparecer abaixo"
echo "    UMA VEZ — copie e guarde antes de continuar, ela não fica salva em nenhum arquivo."
bash scripts/setup.sh

log "subindo a stack (docker compose up -d)"
docker compose up -d

cat <<EOF

==> subot está de pé em ${INSTALL_DIR}

Próximos passos:
  1. Se apareceu uma passphrase de chave SSH acima, rode agora:
       export SUBOT_SSH_KEY_PASSPHRASE='<a passphrase que apareceu>'
       docker compose up -d
     (sem isso os containers sobem, mas toda operação SSH falha até você fazer isso)
  2. bash scripts/pull-models.sh          # baixa os modelos locais do Ollama (qwen2.5:14b / 7b)
  3. python3 scripts/sync-claude-agents.py
  4. Para expor publicamente com TLS: preencha SUBOT_DOMAIN e SUBOT_LETSENCRYPT_EMAIL em .env
     (DNS já apontando pra esta máquina) e rode:
       bash scripts/init-letsencrypt.sh
  5. Restaurando dados de outra instância? Pare a stack ('docker compose down'), rode
     'bash scripts/restore.sh <arquivo.tar.gz>' e suba de novo.

Documentação completa: ${INSTALL_DIR}/README.md
EOF
