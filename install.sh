#!/usr/bin/env bash
# Instalador de um comando só do subot:
#
#   curl -fsSL https://raw.githubusercontent.com/mantenedor/subot/main/install.sh | bash
#
# Repositório atualmente público — o comando acima funciona anônimo. Se voltar a ser privado,
# busque este arquivo via 'gh api repos/mantenedor/subot/contents/install.sh --jq .download_url'
# (link raw com token temporário) e exporte SUBOT_REPO_URL com um token de escopo 'repo' embutido
# (https://x-access-token:<TOKEN>@github.com/mantenedor/subot.git) antes de rodar.
#
# Por padrão faz TUDO sozinho, sem perguntar nada: clona/atualiza, gera a chave SSH (e já usa a
# passphrase gerada nesta mesma execução — você só precisa guardá-la, não reexportar nada agora),
# sobe a stack, baixa os modelos locais e roda o checklist de saúde.
#
# Só existem 2 escolhas interativas, e só aparecem se já houver uma instalação/containers do
# subot no ar: [Enter] atualizar (padrão) | r) reinstalar do zero | b) restaurar de um backup.
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

# Se o instalador for rodado de dentro de um checkout do subot já existente (ex.: 'cd subot &&
# bash install.sh' por engano, ou uma sessão do agent com $PWD já na raiz do repo), o default
# '$PWD/subot' clonaria o repo dentro dele mesmo (subot/subot/, recursivo). Detecta isso checando
# a marca 'name: subot' no docker-compose.yml do próprio $PWD e reusa $PWD em vez de aninhar.
if [ -z "${SUBOT_INSTALL_DIR:-}" ] && [ -d "$PWD/.git" ] && [ -f "$PWD/docker-compose.yml" ] \
    && grep -qx "name: subot" "$PWD/docker-compose.yml"; then
    INSTALL_DIR="$PWD"
else
    INSTALL_DIR="${SUBOT_INSTALL_DIR:-$PWD/subot}"
fi

log() { printf '==> %s\n' "$1"; }
require_cmd() { command -v "$1" >/dev/null 2>&1; }
have_tty() { [ -r /dev/tty ]; }

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
# Instalação/containers do subot já existem? (containers são detectados pelo nome do projeto
# compose 'subot', fixo em docker-compose.yml — então pega até uma instalação em outro diretório.)
# Se sim, e só nesse caso, oferece as 3 únicas escolhas interativas do instalador.
# ---------------------------------------------------------------------------
ALREADY_EXISTS=false
[ -d "$INSTALL_DIR/.git" ] && ALREADY_EXISTS=true
if docker ps -a --filter "label=com.docker.compose.project=subot" -q 2>/dev/null | grep -q .; then
    ALREADY_EXISTS=true
fi

if $ALREADY_EXISTS; then
    CHOICE=""
    if have_tty; then
        echo ""
        echo "Instalação do subot já detectada."
        echo "  [Enter] atualizar e continuar (padrão)"
        echo "  r       reinstalar do zero (apaga $INSTALL_DIR e os containers atuais)"
        echo "  b       restaurar de um backup"
        read -r -p "Escolha: " CHOICE < /dev/tty
    fi

    case "$CHOICE" in
        r|R)
            echo "Isto vai PARAR e REMOVER os containers do subot e APAGAR $INSTALL_DIR."
            read -r -p "Digite 'yes' para confirmar: " CONFIRM < /dev/tty
            [ "$CONFIRM" = "yes" ] || { echo "abortado."; exit 1; }
            [ -f "$INSTALL_DIR/docker-compose.yml" ] && (cd "$INSTALL_DIR" && docker compose down) || true
            rm -rf "$INSTALL_DIR"
            ;;
        b|B)
            if [ ! -d "$INSTALL_DIR/backups" ]; then
                echo "$INSTALL_DIR/backups não existe — copie um backup .tar.gz pra lá e rode de novo."
                exit 1
            fi
            mapfile -t BACKUPS < <(ls -1 "$INSTALL_DIR"/backups/subot-env-backup-*.tar.gz 2>/dev/null || true)
            if [ ${#BACKUPS[@]} -eq 0 ]; then
                echo "nenhum backup encontrado em $INSTALL_DIR/backups."
                exit 1
            fi
            echo "Backups disponíveis:"
            select BK in "${BACKUPS[@]}"; do
                [ -n "${BK:-}" ] && break
            done < /dev/tty
            cd "$INSTALL_DIR"
            docker compose down
            bash scripts/restore.sh "$BK"
            docker compose up -d
            echo "restaurado. Se o backup incluía a chave SSH, exporte SUBOT_SSH_KEY_PASSPHRASE"
            echo "(a passphrase guardada quando ela foi gerada) e rode 'docker compose up -d' de novo."
            exit 0
            ;;
        *)
            log "atualizando instalação existente"
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
echo "    UMA VEZ — copie e guarde num lugar seguro (gerenciador de senhas). Ela já é usada"
echo "    automaticamente nesta execução; só vai fazer falta digitá-la de novo numa reinstalação"
echo "    ou restauração futura."
# 'source' (não 'bash scripts/setup.sh') de propósito: setup.sh gera a passphrase numa variável
# de shell, e sourcing deixa essa variável disponível aqui, no MESMO processo — sem escrever a
# passphrase em nenhum arquivo, e sem precisar de um segundo 'docker compose up' manual depois.
GENERATED_SSH_PASSPHRASE=""
# shellcheck disable=SC1091
source scripts/setup.sh
if [ -n "$GENERATED_SSH_PASSPHRASE" ]; then
    export SUBOT_SSH_KEY_PASSPHRASE="$GENERATED_SSH_PASSPHRASE"
fi

log "subindo a stack (docker compose up -d)"
docker compose up -d

log "registrando o console SSH do agent no Guacamole"
bash scripts/register-console.sh || echo "    falhou — rode 'bash scripts/register-console.sh' depois pra tentar de novo."

log "baixando modelos locais do Ollama (pode demorar alguns minutos)"
bash scripts/pull-models.sh || echo "    falhou — rode 'bash scripts/pull-models.sh' depois pra tentar de novo."

log "projetando agents/*.md para o formato do Claude Code (.claude/agents/)"
python3 scripts/sync-claude-agents.py

log "checklist de saúde"
bash scripts/healthcheck.sh || true

cat <<EOF

==> subot está de pé em ${INSTALL_DIR}

- Se uma passphrase de chave SSH apareceu acima, guarde-a agora num lugar seguro — ela não fica
  salva em nenhum arquivo, e só volta a fazer falta numa reinstalação ou restauração de backup.
- Guacamole fica em http://<IP-desta-VM>:8080/guacamole/ (HTTP, sem TLS — ver README sobre o
  trade-off de segurança dessa porta). Login: usuário/senha em .env (GUACAMOLE_ADMIN_USER/
  GUACAMOLE_ADMIN_PASSWORD, default guacadmin/guacadmin — troque depois do primeiro login). A
  conexão 'subot-console' já está lá, pronta pra abrir um shell dentro do container 'agent'.
- Pra reinstalar do zero ou restaurar de um backup: rode este instalador de novo.

Documentação completa: ${INSTALL_DIR}/README.md
EOF
