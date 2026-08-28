#!/bin/sh
set -eu

echo "[subot-api] iniciando..."
mkdir -p "${SUBOT_AUDIT_DIR:-/opt/subot/data/audit}"
touch "${SUBOT_SSH_DIR:-/opt/subot/secrets/ssh}/known_hosts" 2>/dev/null || true

exec "$@"
