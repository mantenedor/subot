#!/usr/bin/env bash
# Checagem rápida de saúde da stack subot. Sai com código não-zero se algo parecer não saudável.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

FAIL=0

echo "==> docker compose ps"
docker compose ps || FAIL=1

echo "==> modelos do Ollama (dentro do container 'agent')"
docker compose exec -T agent ollama list || FAIL=1

echo "==> guacamole respondendo em http://localhost:8080/guacamole/"
curl -fsS -o /dev/null "http://localhost:8080/guacamole/" || FAIL=1

if [ "$FAIL" -ne 0 ]; then
    echo "==> healthcheck FALHOU"
    exit 1
fi
echo "==> healthcheck OK"
