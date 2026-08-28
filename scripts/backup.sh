#!/usr/bin/env bash
# Backup de TODOS os insumos de ambiente desta instância do subot — tudo que NÃO vive no
# repositório git (que carrega só a ferramenta, sem nenhum dado de instância): .env,
# config/hosts.yaml (inventário real, gerado a partir do .example), secrets/ (chaves SSH,
# certificados TLS, credencial do proxy) e data/ (bancos, gravações, auditoria, modelos locais).
#
# Gera um .tar.gz único, com timestamp, em ./backups/. Por padrão inclui secrets/ — sem eles, o
# backup não é suficiente para restaurar acesso funcional numa VM nova. Use --exclude-secrets só
# se for transportar/guardar o arquivo por um canal em que prefere não incluir material
# criptográfico (nesse caso, leve secrets/ separadamente).
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

EXCLUDE_SECRETS=false
[ "${1:-}" = "--exclude-secrets" ] && EXCLUDE_SECRETS=true

mkdir -p backups
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
OUT="backups/subot-env-backup-${STAMP}.tar.gz"

ARGS=(data)
[ -f .env ] && ARGS+=(.env)
[ -f config/hosts.yaml ] && ARGS+=(config/hosts.yaml)
if ! $EXCLUDE_SECRETS && [ -d secrets ]; then
    ARGS+=(secrets)
fi

tar -czf "$OUT" "${ARGS[@]}"
echo "==> gravado ${OUT}"
echo "    contém: ${ARGS[*]}"
if $EXCLUDE_SECRETS; then
    echo "    (secrets/ excluído — este arquivo sozinho NÃO é suficiente para restaurar acesso SSH/TLS)"
fi
