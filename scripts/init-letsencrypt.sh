#!/usr/bin/env bash
# Bootstrap do certificado Let's Encrypt: o Apache precisa de ALGUM certificado para subir com
# SSLEngine on, mas o certbot (modo webroot) precisa do Apache já rodando na porta 80 para
# responder o desafio ACME. Resolve o "ovo e a galinha" gerando primeiro um certificado
# autoassinado temporário, subindo o Apache com ele, e então pedindo o certificado real.
#
# Pré-requisitos: SUBOT_DOMAIN (DNS já apontando para o IP público desta VM) e
# SUBOT_LETSENCRYPT_EMAIL definidos em .env. Rode DEPOIS de 'docker compose up -d' já ter subido
# guacamole e subot-api (mas pode rodar antes do reverse-proxy).
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

set -a; source .env; set +a

DOMAIN="${SUBOT_DOMAIN:?defina SUBOT_DOMAIN em .env}"
EMAIL="${SUBOT_LETSENCRYPT_EMAIL:?defina SUBOT_LETSENCRYPT_EMAIL em .env}"

CERT_DIR="secrets/tls/letsencrypt"
LIVE_DIR="${CERT_DIR}/live/${DOMAIN}"
mkdir -p "$LIVE_DIR" data/certbot-webroot

if [ ! -f "${LIVE_DIR}/fullchain.pem" ]; then
    echo "==> gerando certificado temporário autoassinado para o Apache conseguir subir"
    openssl req -x509 -nodes -newkey rsa:2048 -days 1 \
        -keyout "${LIVE_DIR}/privkey.pem" \
        -out "${LIVE_DIR}/fullchain.pem" \
        -subj "/CN=${DOMAIN}"
fi

echo "==> subindo reverse-proxy (com o certificado temporário)"
docker compose up -d reverse-proxy

echo "==> descartando o certificado temporário e solicitando o real via certbot (webroot)"
rm -rf "${CERT_DIR}/live/${DOMAIN}" "${CERT_DIR}/archive/${DOMAIN}" "${CERT_DIR}/renewal/${DOMAIN}.conf"

docker compose run --rm --entrypoint certbot certbot certonly \
    --webroot -w /var/www/certbot \
    -d "${DOMAIN}" \
    --email "${EMAIL}" \
    --agree-tos --no-eff-email

echo "==> recarregando o Apache com o certificado real"
docker compose exec reverse-proxy httpd -k graceful

echo "==> subindo o serviço de renovação automática"
docker compose up -d certbot

echo "==> pronto: https://${DOMAIN}/guacamole/"
