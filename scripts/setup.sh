#!/usr/bin/env bash
# Setup de primeira execução: cria diretórios de dados persistidos, gera .env (se ausente) e o
# par de chaves SSH do próprio bastião (se ausente). Seguro para rodar de novo — nunca sobrescreve
# segredos já existentes.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

mkdir -p data/guac-db data/guac-recordings data/audit data/agent-home data/ollama-models data/security-findings
mkdir -p secrets/ssh
mkdir -p containers/guacamole/initdb
mkdir -p backups

# O container 'agent' roda como UID 1000 (usuário 'subot') — diretórios que ele precisa escrever
# (home, modelos do Ollama, auditoria, achados de varredura de vulnerabilidade) precisam pertencer
# a esse UID quando criados pela primeira vez como root no host, senão a montagem bind fica de
# fato somente-leitura pra esse usuário.
chown -R 1000:1000 data/agent-home data/ollama-models data/audit data/security-findings 2>/dev/null || true

if [ ! -f .env ]; then
    echo "==> criando .env a partir de .env.example"
    cp .env.example .env
    GUACDB_PASS="$(openssl rand -base64 24 | tr -d '=+/')"
    if [[ "${OSTYPE:-}" == "darwin"* ]]; then
        sed -i '' "s/^GUACDB_PASSWORD=.*/GUACDB_PASSWORD=${GUACDB_PASS}/" .env
    else
        sed -i "s/^GUACDB_PASSWORD=.*/GUACDB_PASSWORD=${GUACDB_PASS}/" .env
    fi
    echo "    GUACDB_PASSWORD aleatório gerado em .env"
else
    echo "==> .env já existe, mantendo como está"
fi

if [ ! -f config/hosts.yaml ]; then
    echo "==> criando config/hosts.yaml a partir do template (config/hosts.yaml.example)"
    cp config/hosts.yaml.example config/hosts.yaml
else
    echo "==> config/hosts.yaml já existe, mantendo como está"
fi

KEY="secrets/ssh/bastion_id_ed25519"
if [ ! -f "$KEY" ]; then
    echo "==> gerando par de chaves SSH do bastião (protegida por passphrase) em $KEY"
    GENERATED_SSH_PASSPHRASE="$(openssl rand -base64 24 | tr -d '=+/')"
    ssh-keygen -t ed25519 -f "$KEY" -N "$GENERATED_SSH_PASSPHRASE" -C "subot-bastion"
    chmod 600 "$KEY"
    chmod 644 "${KEY}.pub"
    echo ""
    echo "    #################################################################"
    echo "    # GUARDE ESTA PASSPHRASE AGORA — ela NÃO é salva em nenhum arquivo."
    echo "    # Sem ela, a chave privada não abre (mesmo com o arquivo em mãos)."
    echo "    #"
    echo "    #   ${GENERATED_SSH_PASSPHRASE}"
    echo "    #"
    echo "    # Se estiver rodando este script sozinho (fora do install.sh), exporte antes do"
    echo "    # 'docker compose up':"
    echo "    #   export SUBOT_SSH_KEY_PASSPHRASE='${GENERATED_SSH_PASSPHRASE}'"
    echo "    #################################################################"
    echo ""
    echo "    adicione ${KEY}.pub ao authorized_keys de cada host gerenciado"
else
    echo "==> par de chaves SSH do bastião já existe, mantendo como está"
fi

touch secrets/ssh/known_hosts

CONSOLE_KEY="secrets/ssh/guac_console_ed25519"
if [ ! -f "$CONSOLE_KEY" ]; then
    echo "==> gerando par de chaves do console SSH (Guacamole -> container agent, via rede docker)"
    # Sem passphrase de propósito: essa chave só abre uma sessão dropbear que só existe dentro da
    # rede subot_net (nunca publicada no host) e cujo alcance já é limitado a "quem consegue
    # autenticar no Guacamole e abrir essa conexão" — diferente da chave do bastião, que sai pra
    # infraestrutura gerenciada de verdade e por isso é protegida por passphrase.
    ssh-keygen -t ed25519 -f "$CONSOLE_KEY" -N "" -C "subot-guac-console"
    chmod 600 "$CONSOLE_KEY"
    chmod 644 "${CONSOLE_KEY}.pub"
    echo "    chave pronta — use mcp-servers/remote_desktop_connector para criar a conexão no"
    echo "    Guacamole (host 'subot-console' -> agent:2222, ver config/hosts.yaml.example)"
else
    echo "==> chave do console SSH já existe, mantendo como está"
fi

if [ ! -f containers/guacamole/initdb/01-initdb.sql ]; then
    echo "==> gerando schema do banco do Guacamole"
    docker run --rm guacamole/guacamole:1.5.5 /opt/guacamole/bin/initdb.sh --postgresql \
        > containers/guacamole/initdb/01-initdb.sql
else
    echo "==> schema do Guacamole já gerado, mantendo como está"
fi

echo "==> setup concluído. Próximos passos:"
echo "    1. docker compose up -d"
echo "    2. bash scripts/pull-models.sh   (depois do container 'agent' estar de pé)"
echo "    3. Guacamole fica em http://<IP-desta-VM>:8080/guacamole/ (HTTP, sem TLS — ver README"
echo "       sobre o trade-off de segurança dessa porta)."
