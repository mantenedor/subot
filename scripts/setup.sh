#!/usr/bin/env bash
# Setup de primeira execução: cria diretórios de dados persistidos, gera .env (se ausente) e o
# par de chaves SSH do próprio bastião (se ausente). Seguro para rodar de novo — nunca sobrescreve
# segredos já existentes.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

mkdir -p data/guac-db data/guac-recordings data/audit data/agent-home data/ollama-models data/certbot-webroot
mkdir -p secrets/ssh secrets/tls/letsencrypt secrets/reverse-proxy
mkdir -p containers/guacamole/initdb
mkdir -p backups

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
    echo "==> gerando par de chaves SSH do bastião em $KEY"
    ssh-keygen -t ed25519 -f "$KEY" -N "" -C "subot-bastion"
    chmod 600 "$KEY"
    chmod 644 "${KEY}.pub"
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

HTPASSWD="secrets/reverse-proxy/htpasswd"
if [ ! -f "$HTPASSWD" ]; then
    echo "==> gerando credencial Basic Auth para /api/ no reverse-proxy"
    API_USER="$(grep -E '^SUBOT_API_BASIC_AUTH_USER=' .env | cut -d= -f2)"
    API_USER="${API_USER:-admin}"
    API_PASS="$(openssl rand -base64 18 | tr -d '=+/')"
    HASH="$(openssl passwd -apr1 "$API_PASS")"
    echo "${API_USER}:${HASH}" > "$HTPASSWD"
    echo "${API_USER}:${API_PASS}" > secrets/reverse-proxy/htpasswd-password.txt
    chmod 600 secrets/reverse-proxy/htpasswd-password.txt
    echo "    usuário: ${API_USER}"
    echo "    senha:   ${API_PASS}  (salva também em secrets/reverse-proxy/htpasswd-password.txt)"
else
    echo "==> credencial Basic Auth de /api/ já existe, mantendo como está"
fi

echo "==> setup concluído. Próximos passos:"
echo "    1. bash scripts/pull-models.sh   (depois de 'docker compose up -d' subir o ollama)"
echo "    2. docker compose up -d"
echo "    3. se for expor publicamente com Let's Encrypt: preencha SUBOT_DOMAIN e"
echo "       SUBOT_LETSENCRYPT_EMAIL em .env, garanta que o DNS já aponta pra esta VM, e rode"
echo "       bash scripts/init-letsencrypt.sh"
