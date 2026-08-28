#!/usr/bin/env bash
# Setup de primeira execução: cria diretórios de dados persistidos, gera .env (se ausente) e o
# par de chaves SSH do próprio bastião (se ausente). Seguro para rodar de novo — nunca sobrescreve
# segredos já existentes.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

mkdir -p data/guac-db data/guac-recordings data/audit data/agent-home data/ollama-models data/caddy-data data/caddy-config
mkdir -p secrets/ssh
mkdir -p containers/guacamole/initdb
mkdir -p backups

# O container 'agent' roda como UID 1000 (usuário 'subot') — diretórios que ele precisa escrever
# (home, modelos do Ollama, auditoria) precisam pertencer a esse UID quando criados pela primeira
# vez como root no host, senão a montagem bind fica de fato somente-leitura pra esse usuário.
chown -R 1000:1000 data/agent-home data/ollama-models data/audit 2>/dev/null || true

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

if [ ! -f containers/guacamole/initdb/01-initdb.sql ]; then
    echo "==> gerando schema do banco do Guacamole"
    docker run --rm guacamole/guacamole:1.5.5 /opt/guacamole/bin/initdb.sh --postgresql \
        > containers/guacamole/initdb/01-initdb.sql
else
    echo "==> schema do Guacamole já gerado, mantendo como está"
fi

if ! grep -qE '^SUBOT_API_BASIC_AUTH_HASH=.+' .env 2>/dev/null; then
    echo "==> gerando credencial Basic Auth para /api/ no Caddy"
    API_USER="$(grep -E '^SUBOT_API_BASIC_AUTH_USER=' .env | cut -d= -f2)"
    API_USER="${API_USER:-admin}"
    API_PASS="$(openssl rand -base64 18 | tr -d '=+/')"
    # hash bcrypt via o próprio binário do Caddy (é o formato que o basicauth dele exige — não é
    # o mesmo formato do 'openssl passwd -apr1' usado por Apache/htpasswd)
    HASH="$(docker run --rm caddy:2 caddy hash-password --plaintext "$API_PASS")"
    if grep -qE '^SUBOT_API_BASIC_AUTH_HASH=' .env; then
        ESCAPED_HASH="$(printf '%s' "$HASH" | sed 's/[&/\]/\\&/g')"
        sed -i "s|^SUBOT_API_BASIC_AUTH_HASH=.*|SUBOT_API_BASIC_AUTH_HASH=${ESCAPED_HASH}|" .env
    else
        echo "SUBOT_API_BASIC_AUTH_HASH=${HASH}" >> .env
    fi
    mkdir -p secrets/caddy
    echo "${API_USER}:${API_PASS}" > secrets/caddy/api-password.txt
    chmod 600 secrets/caddy/api-password.txt
    echo "    usuário: ${API_USER}"
    echo "    senha:   ${API_PASS}  (salva também em secrets/caddy/api-password.txt)"
else
    echo "==> credencial Basic Auth de /api/ já existe (.env), mantendo como está"
fi

echo "==> setup concluído. Próximos passos:"
echo "    1. docker compose up -d"
echo "    2. bash scripts/pull-models.sh   (depois do container 'agent' estar de pé)"
echo "    3. Pra expor com domínio público de verdade: preencha SUBOT_DOMAIN e"
echo "       SUBOT_LETSENCRYPT_EMAIL em .env e suba de novo — o Caddy emite o certificado"
echo "       Let's Encrypt sozinho, sem passo manual nenhum."
