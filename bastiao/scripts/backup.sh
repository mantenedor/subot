#!/usr/bin/env bash
# Backup de TODOS os insumos de ambiente desta instância do subot — tudo que NÃO vive no
# repositório git (que carrega só a ferramenta, sem nenhum dado de instância): bastiao/.env,
# config/hosts.yaml (inventário real, gerado a partir do .example), bastiao/secrets/ (chaves SSH,
# certificados TLS, credencial do proxy) e data/ (bancos, gravações, auditoria, modelos locais).
#
# Gera um .tar.gz único, com timestamp, em ./backups/ (raiz do repo). Por padrão inclui
# bastiao/secrets/ — sem eles, o backup não é suficiente para restaurar acesso funcional numa VM
# nova. Use --exclude-secrets só se for transportar/guardar o arquivo por um canal em que prefere
# não incluir material criptográfico (nesse caso, leve bastiao/secrets/ separadamente).
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../.."

EXCLUDE_SECRETS=false
[ "${1:-}" = "--exclude-secrets" ] && EXCLUDE_SECRETS=true

mkdir -p backups
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
OUT="backups/subot-env-backup-${STAMP}.tar.gz"

ARGS=(data)
DISPLAY=(data)
[ -f config/hosts.yaml ] && ARGS+=(config/hosts.yaml) && DISPLAY+=(config/hosts.yaml)
if ! $EXCLUDE_SECRETS && [ -d bastiao/secrets ]; then
    ARGS+=(bastiao/secrets)
    DISPLAY+=(bastiao/secrets)
fi

# bastiao/.env pode conter SUBOT_SSH_KEY_PASSPHRASE preenchida (opção prática, ver comentário no
# próprio .env) — nunca vai pro mesmo backup que já carrega bastiao/secrets/ssh/, senão o arquivo
# sozinho destrava a chave sem precisar de mais nada. Empacota uma cópia redigida em vez do
# arquivo real.
if [ -f bastiao/.env ]; then
    TMPDIR="$(mktemp -d)"
    trap 'rm -rf "$TMPDIR"' EXIT
    mkdir -p "$TMPDIR/bastiao"
    sed 's/^SUBOT_SSH_KEY_PASSPHRASE=.*/SUBOT_SSH_KEY_PASSPHRASE=__REDACTED_NAO_INCLUIDO_NO_BACKUP__/' bastiao/.env > "$TMPDIR/bastiao/.env"
    ARGS+=(-C "$TMPDIR" bastiao/.env)
    DISPLAY+=("bastiao/.env (com passphrase redigida)")
fi

tar -czf "$OUT" "${ARGS[@]}"
echo "==> gravado ${OUT}"
echo "    contém: ${DISPLAY[*]}"
if $EXCLUDE_SECRETS; then
    echo "    (secrets/ excluído — este arquivo sozinho NÃO é suficiente para restaurar acesso SSH/TLS)"
fi

echo ""
echo "    #################################################################"
echo "    # ATENÇÃO — a passphrase da chave SSH do bastião NÃO está neste"
echo "    # backup, mesmo que esteja preenchida no seu .env local (redigida"
echo "    # de propósito: nunca fica no mesmo arquivo que a chave cifrada,"
echo "    # senão o backup sozinho já destrava o acesso SSH pra quem o pegar)."
echo "    # Sem ela guardada em algum lugar à parte (gerenciador de senha,"
echo "    # cofre da empresa), restaurar este backup numa VM nova te dá a"
echo "    # chave cifrada de volta, mas SEM COMO ABRI-LA — perda permanente"
echo "    # de acesso SSH, só resolve regenerando e redistribuindo uma chave"
echo "    # nova pra todos os hosts gerenciados."
echo "    #"
echo "    # Se ainda não guardou a passphrase que apareceu quando a chave"
echo "    # foi gerada (scripts/setup.sh ou rotate-ssh-keys.sh), faça isso"
echo "    # AGORA, antes deste backup ser a sua única cópia."
echo "    #################################################################"
