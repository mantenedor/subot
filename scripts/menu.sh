#!/usr/bin/env bash
# Menu interativo de próximos passos pós-instalação do subot.
#
# Roda inteiro no HOST (a VM onde o subot foi instalado) — cada opção deixa explícito, antes de
# executar, se o comando roda só no host, dentro de um container, ou os dois (host disparando algo
# dentro de um container via 'docker compose exec'/'docker compose run').
#
# Funciona tanto chamado direto ('bash scripts/menu.sh') quanto no fim do install.sh via
# 'curl | bash' — nesse segundo caso o stdin normal está ocupado pelo conteúdo do próprio script
# baixado, então a leitura das opções do menu usa /dev/tty explicitamente, não stdin.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

TTY=/dev/tty
if [ ! -r "$TTY" ]; then
    echo "Sem terminal interativo disponível (stdin não é um TTY) — pulando o menu."
    echo "Rode os passos manualmente depois, ou 'bash scripts/menu.sh' de um terminal de verdade."
    exit 0
fi

pause() {
    echo ""
    read -r -p "Pressione Enter para voltar ao menu... " _ < "$TTY" || true
}

env_var_set() {
    grep -qE "^${1}=.+" .env 2>/dev/null
}

print_menu() {
    cat <<'MENU'

==================================================================
 subot — próximos passos (rode as opções na ordem que fizer sentido)
==================================================================
 1) Baixar modelos de IA locais (Ollama)
    [HOST dispara -> executa DENTRO do container 'ollama']
 2) Configurar HTTPS/Let's Encrypt (Apache + certbot)
    [HOST dispara -> executa DENTRO dos containers 'reverse-proxy'/'certbot']
 3) Rodar checklist de saúde da instalação
    [HOST apenas — consulta os containers de fora, via curl/docker]
 4) Ver status dos containers
    [HOST apenas]
 5) Verificar se a passphrase da chave SSH está ativa
    [HOST apenas — lê logs do container 'subot-agent', não entra nele]
 6) Projetar agentes canônicos pro formato Claude Code
    [HOST apenas — script Python local, não toca em nenhum container]
 0) Sair
==================================================================
MENU
}

while true; do
    print_menu
    read -r -p "Escolha uma opção [0-6]: " choice < "$TTY" || break

    case "$choice" in
        1)
            echo ""
            echo "[HOST] Vou rodar scripts/pull-models.sh. Ele roda no host, e usa"
            echo "'docker compose exec ollama ollama pull <modelo>' pra baixar cada modelo DENTRO"
            echo "do container ollama (o download acontece lá dentro, não no host)."
            bash scripts/pull-models.sh || echo "falhou — confira se a stack está no ar (opção 4)."
            pause
            ;;
        2)
            echo ""
            if ! env_var_set SUBOT_DOMAIN || ! env_var_set SUBOT_LETSENCRYPT_EMAIL; then
                echo "SUBOT_DOMAIN e/ou SUBOT_LETSENCRYPT_EMAIL ainda não estão preenchidos em .env"
                echo "(arquivo no HOST, em $(pwd)/.env). Edite-o agora e volte a esta opção depois."
                pause
                continue
            fi
            echo "[HOST] Vou rodar scripts/init-letsencrypt.sh. Ele roda no host, sobe/reconfigura"
            echo "o container 'reverse-proxy' e dispara 'docker compose run certbot ...' — o"
            echo "certificado é emitido DENTRO de um container efêmero do certbot."
            bash scripts/init-letsencrypt.sh || echo "falhou — confira o DNS do domínio e tente de novo."
            pause
            ;;
        3)
            echo ""
            echo "[HOST] Vou rodar scripts/healthcheck.sh — roda inteiro no host: 'docker compose"
            echo "ps', 'curl' contra os endpoints publicados e 'docker compose exec ollama ollama"
            echo "list' (esse último dispara do host, lista o que está DENTRO do container ollama)."
            bash scripts/healthcheck.sh || true
            pause
            ;;
        4)
            echo ""
            echo "[HOST] docker compose ps"
            docker compose ps
            pause
            ;;
        5)
            echo ""
            echo "[HOST] Lendo os logs do container 'subot-agent' à procura do aviso de passphrase"
            echo "(o log é lido de fora — 'docker compose logs' — não entro no container)."
            if docker compose logs subot-agent 2>/dev/null | grep -qi "passphrase"; then
                echo ""
                echo "AVISO ENCONTRADO — a passphrase não está ativa nos containers. No HOST, rode:"
                echo "  export SUBOT_SSH_KEY_PASSPHRASE='<a passphrase que o setup.sh mostrou>'"
                echo "  docker compose up -d"
            else
                echo ""
                echo "Nenhum aviso de passphrase nos logs — parece OK."
            fi
            pause
            ;;
        6)
            echo ""
            echo "[HOST] Vou rodar scripts/sync-claude-agents.py — script Python que só lê/escreve"
            echo "arquivos deste diretório no host (agents/*.md -> .claude/agents/*.md); não toca"
            echo "em nenhum container."
            python3 scripts/sync-claude-agents.py 2>/dev/null || python scripts/sync-claude-agents.py
            pause
            ;;
        0)
            echo "Saindo do menu. Rode 'bash scripts/menu.sh' quando quiser voltar aqui."
            break
            ;;
        *)
            echo "Opção inválida: '$choice'."
            pause
            ;;
    esac
done
