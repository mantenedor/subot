#!/usr/bin/env bash
# Cliente do gate de escalação de privilégio — 'subot' chama isto no lugar de 'sudo <comando>'.
# 'subot' não tem NENHUMA entrada de sudo neste host: este script não executa nada diretamente,
# só registra um pedido (comando + motivo) no spool e bloqueia esperando o daemon root
# (subot-gate-daemon.sh) decidir, via aprovação humana no Telegram. Fail-closed: qualquer caminho
# de erro sai != 0 sem que nada tenha sido executado.
set -euo pipefail

REQ_DIR=/opt/subot-gate/var/requests
RESP_DIR=/opt/subot-gate/var/responses
# Deve ser MAIOR que TIMEOUT_SECONDS do daemon (telegram.env) + folga de rede — senão o cliente
# desiste antes do próprio fail-closed do servidor ter chance de responder "timeout".
CLIENT_WAIT_SECONDS="${SUBOT_GATE_CLIENT_WAIT:-330}"

if [ "$#" -ne 2 ]; then
    echo "uso: $(basename "$0") '<comando>' '<motivo>'" >&2
    exit 1
fi
cmd="$1"
reason="$2"

# O Telegram rejeita 'sendMessage' com texto acima de ~4096 caracteres (o template ainda soma
# host/usuário/motivo/tags HTML por cima do comando em si). Validar aqui, fail-closed, ANTES de
# gravar o pedido evita depender do daemon lidar bem com isso do outro lado — e mesmo com esse
# tratamento lá (ver send_notification), um comando que nunca cabe numa mensagem nunca teria como
# ser aprovado de qualquer forma, então nem vale gerar o pedido.
MAX_CMD_LEN="${SUBOT_GATE_MAX_CMD_LEN:-1500}"
MAX_REASON_LEN="${SUBOT_GATE_MAX_REASON_LEN:-500}"
if [ "${#cmd}" -gt "$MAX_CMD_LEN" ]; then
    echo "subot-gate: comando com ${#cmd} caracteres, acima do limite de ${MAX_CMD_LEN} (não caberia na notificação de aprovação)." >&2
    exit 2
fi
if [ "${#reason}" -gt "$MAX_REASON_LEN" ]; then
    echo "subot-gate: motivo com ${#reason} caracteres, acima do limite de ${MAX_REASON_LEN}." >&2
    exit 2
fi

# 128 bits de /dev/urandom — não-adivinhável, é a única credencial que 'subot' tem para reler a
# própria resposta depois (o diretório de respostas não pode ser listado, só aberto por nome).
req_id="$(od -An -tx1 -N16 /dev/urandom | tr -d ' \n')"
tmp="${REQ_DIR}/.tmp.$$.${req_id}"
final="${REQ_DIR}/${req_id}"

# Comando e motivo em base64 numa única linha cada: evita qualquer ambiguidade de escaping ao
# serializar em formato 'chave=valor' de texto simples (novas linhas, '=', aspas no comando real).
{
    printf 'schema=1\n'
    printf 'ts=%s\n' "$(date -u +%s)"
    printf 'host=%s\n' "$(hostname -f 2>/dev/null || hostname)"
    printf 'requested_by=%s\n' "$(id -un)"
    printf 'command_b64=%s\n' "$(printf '%s' "$cmd" | base64 -w0)"
    printf 'reason_b64=%s\n' "$(printf '%s' "$reason" | base64 -w0)"
} > "$tmp"
# mv dentro do mesmo diretório é atômico e só precisa de 'w'+'x' no diretório, nunca 'r' —
# 'subot' nunca consegue listar/ler pedidos de outra sessão sua.
mv -- "$tmp" "$final"

resp="${RESP_DIR}/${req_id}"
deadline=$(( $(date +%s) + CLIENT_WAIT_SECONDS ))
while [ ! -f "$resp" ]; do
    if [ "$(date +%s)" -ge "$deadline" ]; then
        cat >&2 <<EOF
subot-gate: sem resposta em ${CLIENT_WAIT_SECONDS}s (request_id=${req_id}).
O pedido pode continuar pendente do lado humano (ex.: "Adiar") e ser decidido mais tarde de forma
assíncrona, sem que esta chamada esteja mais esperando — confira a auditoria depois.
EOF
        exit 12
    fi
    sleep 1
done

status="$(grep -m1 '^status=' "$resp" | cut -d= -f2-)"
case "$status" in
    approved)
        exit_code="$(grep -m1 '^exit_code=' "$resp" | cut -d= -f2-)"
        grep -m1 '^stdout_b64=' "$resp" | cut -d= -f2- | base64 -d
        grep -m1 '^stderr_b64=' "$resp" | cut -d= -f2- | base64 -d >&2
        exit "$exit_code"
        ;;
    denied)
        echo "subot-gate: negado por humano (request_id=${req_id})." >&2
        exit 10
        ;;
    timeout)
        echo "subot-gate: sem decisão humana dentro do prazo — negado automaticamente (request_id=${req_id})." >&2
        exit 11
        ;;
    error)
        grep -m1 '^stderr_b64=' "$resp" | cut -d= -f2- | base64 -d >&2
        exit 13
        ;;
    *)
        echo "subot-gate: resposta em formato inesperado (request_id=${req_id})." >&2
        exit 1
        ;;
esac
