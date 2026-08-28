#!/usr/bin/env bash
# Checagem rápida de saúde da stack subot. Sai com código não-zero se algo parecer não saudável.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

[ -f .env ] && set -a && source .env && set +a

FAIL=0

echo "==> docker compose ps"
docker compose ps || FAIL=1

echo "==> modelos do Ollama (dentro do container 'agent')"
docker compose exec -T agent ollama list || FAIL=1

echo "==> caddy respondendo em https://localhost/guacamole/"
curl -fsSk -o /dev/null "https://localhost/guacamole/" || FAIL=1

if [ -n "${SUBOT_DOMAIN:-}" ] && [ "$SUBOT_DOMAIN" != "localhost" ]; then
    echo "==> https://${SUBOT_DOMAIN}/guacamole/ (certificado real)"
    curl -fsS -o /dev/null "https://${SUBOT_DOMAIN}/guacamole/" || FAIL=1
fi

if [ "$FAIL" -ne 0 ]; then
    echo "==> healthcheck FALHOU"
    exit 1
fi
echo "==> healthcheck OK"
