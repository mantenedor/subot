#!/usr/bin/env bash
# Gera um certificado AUTOASSINADO local (sem Let's Encrypt) só para testar o reverse-proxy sem
# precisar de domínio/DNS público ainda. NÃO é adequado para produção pública — troque por
# scripts/init-letsencrypt.sh assim que tiver um domínio real com DNS apontando pra esta VM.
#
# O navegador vai mostrar aviso de certificado não confiável ao acessar — é esperado, é
# autoassinado; para produção pública use scripts/init-letsencrypt.sh (Let's Encrypt de verdade).
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

set -a; [ -f .env ] && source .env; set +a
DOMAIN="${SUBOT_DOMAIN:-localhost}"

CERT_DIR="secrets/tls/letsencrypt"
LIVE_DIR="${CERT_DIR}/live/${DOMAIN}"
mkdir -p "$LIVE_DIR"

if [ -f "${LIVE_DIR}/fullchain.pem" ]; then
    echo "já existe um certificado em ${LIVE_DIR} — remova-o antes se quiser gerar outro autoassinado"
    echo "(ou já é um Let's Encrypt de verdade — nesse caso não mexa nele)."
else
    echo "==> gerando certificado autoassinado para '${DOMAIN}' (só para teste local, válido 365 dias)"
    openssl req -x509 -nodes -newkey rsa:2048 -days 365 \
        -keyout "${LIVE_DIR}/privkey.pem" \
        -out "${LIVE_DIR}/fullchain.pem" \
        -subj "/CN=${DOMAIN}"
fi

echo "==> subindo/recarregando o reverse-proxy"
docker compose up -d reverse-proxy

cat <<EOF

==> pronto. Acesse (o navegador vai avisar que o certificado não é confiável — esperado, é
    autoassinado, aceite o risco pra continuar):

      https://<IP-desta-VM>/guacamole/

Quando tiver um domínio real com DNS apontando pra cá, rode 'bash scripts/init-letsencrypt.sh'
para trocar por um certificado de verdade (Let's Encrypt).
EOF
