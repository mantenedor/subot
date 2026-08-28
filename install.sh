#!/usr/bin/env bash
# Instalador de um comando só do subot, para uma VM nova:
#
#   curl -fsSL https://raw.githubusercontent.com/mantenedor/subot/main/install.sh | bash
#
# Repositório atualmente público — o comando acima funciona anônimo. Se voltar a ser privado,
# busque este arquivo via 'gh api repos/mantenedor/subot/contents/install.sh --jq .download_url'
# (link raw com token temporário) e exporte SUBOT_REPO_URL com um token de escopo 'repo' embutido
# (https://x-access-token:<TOKEN>@github.com/mantenedor/subot.git) antes de rodar.
#
# Idempotente: se detectar instalação/containers/imagens/modelos já existentes (em QUALQUER
# diretório, não só no destino atual), pergunta interativamente o que fazer — atualizar, recriar
# do zero (destrutivo, com confirmação), restaurar de um backup, ou só abrir o menu de próximos
# passos. Nunca sobrescreve .env / secrets/ / config/hosts.yaml existentes — scripts/setup.sh já
# preserva tudo isso.
#
# Variáveis de ambiente que ajustam o comportamento (opcional):
#   SUBOT_REPO_URL   URL do repositório git (default: aponte para o seu fork/org antes de publicar)
#   SUBOT_REPO_REF   branch/tag a clonar (default: main)
#   SUBOT_INSTALL_DIR diretório de destino (default: ./subot, dentro do diretório onde o
#                      instalador foi executado — não $HOME, para respeitar 'cd /algum/lugar &&
#                      curl ... | bash')
set -euo pipefail

REPO_URL="${SUBOT_REPO_URL:-https://github.com/mantenedor/subot.git}"
REPO_REF="${SUBOT_REPO_REF:-main}"
INSTALL_DIR="${SUBOT_INSTALL_DIR:-$PWD/subot}"

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

# ---------------------------------------------------------------------------
# [HOST] Detecta instalação/containers/imagens/modelos já existentes ANTES de clonar/subir
# qualquer coisa. Containers/imagens são detectados globalmente (pelo nome do projeto compose
# 'subot', fixo em docker-compose.yml via 'name:'), então isso pega até instalações abandonadas
# em outro diretório (ex.: uma tentativa anterior em /root enquanto agora se instala em /opt).
# ---------------------------------------------------------------------------
EXISTING_DIR=false
[ -d "$INSTALL_DIR/.git" ] && EXISTING_DIR=true

EXISTING_CONTAINERS="$(docker ps -a --filter "label=com.docker.compose.project=subot" --format '{{.Names}} ({{.Status}})' 2>/dev/null || true)"
EXISTING_IMAGES="$(docker images --format '{{.Repository}}:{{.Tag}}' 2>/dev/null | grep -E '^subot-(subot-)?(agent|api)' || true)"

OLLAMA_CONTAINER="$(docker ps --filter "label=com.docker.compose.project=subot" --filter "label=com.docker.compose.service=ollama" --format '{{.Names}}' 2>/dev/null | head -1 || true)"
EXISTING_MODELS=""
if [ -n "$OLLAMA_CONTAINER" ]; then
    EXISTING_MODELS="$(docker exec "$OLLAMA_CONTAINER" ollama list 2>/dev/null | tail -n +2 | awk '{print $1}' | paste -sd ', ' - 2>/dev/null || true)"
fi

EXISTING_BACKUPS=""
[ -d "$INSTALL_DIR/backups" ] && EXISTING_BACKUPS="$(ls -1 "$INSTALL_DIR/backups"/subot-env-backup-*.tar.gz 2>/dev/null || true)"

if $EXISTING_DIR || [ -n "$EXISTING_CONTAINERS" ] || [ -n "$EXISTING_IMAGES" ]; then
    echo ""
    echo "==> [HOST] estado existente detectado:"
    echo "    diretório $INSTALL_DIR já é um clone do subot: $([ "$EXISTING_DIR" = true ] && echo sim || echo não)"
    echo "    containers do subot (docker, em qualquer diretório): ${EXISTING_CONTAINERS:-nenhum}"
    echo "    imagens já construídas (subot-agent/subot-api): ${EXISTING_IMAGES:-nenhuma}"
    echo "    modelos do Ollama já baixados: ${EXISTING_MODELS:-nenhum (ou o container ollama não está rodando)}"
    echo "    backups disponíveis em $INSTALL_DIR/backups: ${EXISTING_BACKUPS:-nenhum}"
    echo ""

    if [ -r /dev/tty ]; then
        echo "O que você quer fazer?"
        echo "  1) Atualizar a instalação existente [HOST: git pull + docker compose up -d] (recomendado)"
        echo "  2) Recriar do zero — PARA e REMOVE containers/dados atuais, clona de novo [HOST] (destrutivo)"
        echo "  3) Restaurar a partir de um backup existente [HOST]"
        echo "  4) Só abrir o menu de próximos passos (modelos, reverse proxy, healthcheck...) [HOST]"
        echo "  5) Cancelar, não fazer nada"
        read -r -p "Escolha [1-5]: " PREFLIGHT_CHOICE < /dev/tty
    else
        echo "Sem terminal interativo (stdin ocupado pelo próprio script, ou rodando sem TTY) —"
        echo "assumindo opção 1 (atualizar instalação existente)."
        PREFLIGHT_CHOICE=1
    fi

    case "$PREFLIGHT_CHOICE" in
        2)
            echo "Isto vai [HOST] PARAR e REMOVER os containers do subot e APAGAR $INSTALL_DIR."
            read -r -p "Digite 'yes' para confirmar: " CONFIRM < /dev/tty
            if [ "$CONFIRM" != "yes" ]; then
                echo "abortado."
                exit 1
            fi
            if [ -f "$INSTALL_DIR/docker-compose.yml" ]; then
                log "[HOST] docker compose down (em $INSTALL_DIR)"
                (cd "$INSTALL_DIR" && docker compose down) || true
            fi
            log "[HOST] removendo $INSTALL_DIR"
            rm -rf "$INSTALL_DIR"
            EXISTING_DIR=false
            ;;
        3)
            echo "Backups disponíveis em $INSTALL_DIR/backups:"
            echo "${EXISTING_BACKUPS:-  nenhum encontrado}"
            echo ""
            echo "Rode manualmente, no HOST:"
            echo "  cd $INSTALL_DIR"
            echo "  docker compose down"
            echo "  bash scripts/restore.sh <arquivo.tar.gz>"
            echo "  docker compose up -d"
            exit 0
            ;;
        4)
            if [ -f "$INSTALL_DIR/scripts/menu.sh" ]; then
                cd "$INSTALL_DIR"
                exec bash scripts/menu.sh
            else
                echo "$INSTALL_DIR/scripts/menu.sh não encontrado (instalação incompleta?) — escolha" >&2
                echo "outra opção ou rode a instalação primeiro." >&2
                exit 1
            fi
            ;;
        5)
            echo "cancelado, nada foi alterado."
            exit 0
            ;;
        *)
            log "prosseguindo com atualização da instalação existente"
            ;;
    esac
fi

# Sem terminal pra digitar usuário/senha num 'curl | bash' — falha rápido com uma mensagem clara
# em vez de o git ficar pendurado esperando um prompt interativo que nunca vem.
export GIT_TERMINAL_PROMPT=0

if [ -d "$INSTALL_DIR/.git" ]; then
    log "diretório existente em $INSTALL_DIR — atualizando (git pull)"
    if ! git -C "$INSTALL_DIR" pull --ff-only; then
        echo "git pull falhou — se o repositório é privado, SUBOT_REPO_URL precisa ter um token" >&2
        echo "embutido (https://x-access-token:<TOKEN>@github.com/...) — ver README." >&2
        exit 1
    fi
else
    log "clonando $REPO_URL (ref: $REPO_REF) em $INSTALL_DIR"
    if ! git clone --branch "$REPO_REF" --depth 1 "$REPO_URL" "$INSTALL_DIR"; then
        echo "git clone falhou — se o repositório é privado, exporte SUBOT_REPO_URL com um token" >&2
        echo "embutido ANTES deste comando:" >&2
        echo "  export SUBOT_REPO_URL='https://x-access-token:<TOKEN>@github.com/mantenedor/subot.git'" >&2
        echo "(token com escopo 'repo' — ver README, seção 'Deploy em uma VM nova')." >&2
        exit 1
    fi
fi

cd "$INSTALL_DIR"

log "rodando scripts/setup.sh (gera .env, hosts.yaml, chaves SSH, credenciais — nunca sobrescreve o que já existe)"
echo "    ATENÇÃO: se este for o primeiro setup, uma passphrase da chave SSH vai aparecer abaixo"
echo "    UMA VEZ — copie e guarde antes de continuar, ela não fica salva em nenhum arquivo."
bash scripts/setup.sh

log "[HOST] subindo a stack (docker compose up -d)"
docker compose up -d

cat <<EOF

==> subot está de pé em ${INSTALL_DIR}

IMPORTANTE: se uma passphrase de chave SSH apareceu acima (primeira instalação), este primeiro
'docker compose up -d' subiu ANTES dela existir no ambiente — os containers estão de pé, mas
toda operação SSH vai falhar até você, no HOST, rodar:
  export SUBOT_SSH_KEY_PASSPHRASE='<a passphrase que apareceu acima>'
  docker compose up -d
(o menu abaixo tem uma opção pra confirmar se isso já está OK.)

Restaurando dados de outra instância em vez de uma instalação nova? Pare a stack agora
('docker compose down'), rode 'bash scripts/restore.sh <arquivo.tar.gz>' e suba de novo antes de
usar o menu abaixo.

Documentação completa: ${INSTALL_DIR}/README.md
EOF

bash scripts/menu.sh
