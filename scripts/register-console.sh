#!/usr/bin/env bash
# Cria a conexão SSH "subot-console" no Guacamole automaticamente (aponta pro container 'agent'
# na rede docker interna, porta 2222, usuário 'subot', autenticado pela chave gerada em
# scripts/setup.sh). Idempotente — não duplica se já existir. Precisa do guacamole e do agent já
# respondendo (rodar depois de 'docker compose up'). Só usa curl + python3 (stdlib, sem
# dependências extras) — roda direto no host, sem precisar entrar em nenhum container.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
set -a; [ -f .env ] && source .env; set +a

GUAC_URL="http://localhost:8080/guacamole"
GUAC_USER="${GUACAMOLE_ADMIN_USER:-guacadmin}"
GUAC_PASS="${GUACAMOLE_ADMIN_PASSWORD:-guacadmin}"
KEY_FILE="secrets/ssh/guac_console_ed25519"

if [ ! -f "$KEY_FILE" ]; then
    echo "secrets/ssh/guac_console_ed25519 não encontrada — rode scripts/setup.sh primeiro." >&2
    exit 1
fi

echo "==> aguardando o Guacamole responder em $GUAC_URL"
ok=false
for _ in $(seq 1 30); do
    if curl -fsS -o /dev/null "$GUAC_URL/"; then
        ok=true
        break
    fi
    sleep 2
done
if [ "$ok" != true ]; then
    echo "Guacamole não respondeu a tempo em $GUAC_URL — suba a stack primeiro." >&2
    exit 1
fi

TOKEN="$(curl -fsS -X POST "$GUAC_URL/api/tokens" \
    -d "username=${GUAC_USER}" -d "password=${GUAC_PASS}" \
    | python3 -c 'import json,sys; print(json.load(sys.stdin)["authToken"])')"

ALREADY="$(curl -fsS "$GUAC_URL/api/session/data/postgresql/connections?token=${TOKEN}" \
    | python3 -c 'import json,sys; d=json.load(sys.stdin); print("yes" if any(c.get("name")=="subot-console" for c in d.values()) else "no")')"

if [ "$ALREADY" = "yes" ]; then
    echo "==> conexão 'subot-console' já existe no Guacamole, nada a fazer"
    exit 0
fi

PAYLOAD="$(python3 -c '
import json, sys
key = open(sys.argv[1]).read()
print(json.dumps({
    "parentIdentifier": "ROOT",
    "name": "subot-console",
    "protocol": "ssh",
    "parameters": {"hostname": "agent", "port": "2222", "username": "subot", "private-key": key},
    "attributes": {},
}))
' "$KEY_FILE")"

curl -fsS -X POST "$GUAC_URL/api/session/data/postgresql/connections?token=${TOKEN}" \
    -H "Content-Type: application/json" -d "$PAYLOAD" > /dev/null

echo "==> conexão 'subot-console' criada no Guacamole — abra http://<IP-desta-VM>:8080/guacamole/,"
echo "    faça login e clique nela pra cair direto num shell dentro do container 'agent'."
