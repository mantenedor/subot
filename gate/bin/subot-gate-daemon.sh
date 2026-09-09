#!/usr/bin/env bash
# Daemon root do gate de escalação de privilégio — o único processo que de fato executa um
# comando privilegiado neste host, e só depois de um humano aprovar via Telegram. Roda como
# serviço systemd (subot-gate.service), instância única garantida por 'flock' no ExecStart. Nunca
# roda como 'subot' e não deve ter permissão de escrita para 'subot' (ver install-gate.sh).
set -euo pipefail

BASE=/opt/subot-gate
# shellcheck source=/opt/subot-gate/etc/telegram.env
source "$BASE/etc/telegram.env"

: "${TELEGRAM_BOT_TOKEN:?TELEGRAM_BOT_TOKEN não definido em telegram.env}"
: "${TELEGRAM_CHAT_ID:?TELEGRAM_CHAT_ID não definido em telegram.env}"
: "${TELEGRAM_AUTHORIZED_IDS:?TELEGRAM_AUTHORIZED_IDS não definido em telegram.env (chat é um grupo — allowlist é obrigatória)}"
TIMEOUT_SECONDS="${TIMEOUT_SECONDS:-300}"
API="${TELEGRAM_API_BASE:-https://api.telegram.org}/bot${TELEGRAM_BOT_TOKEN}"

REQ_DIR="$BASE/var/requests"
RESP_DIR="$BASE/var/responses"
STATE_DIR="$BASE/var/state"
PROC_DIR="$STATE_DIR/processing"
ARCHIVE_DIR="$STATE_DIR/archive"
OFFSET_FILE="$STATE_DIR/telegram_offset"
LOG="$BASE/var/log/gate-audit.jsonl"
PURGE_AFTER_DAYS="${PURGE_AFTER_DAYS:-30}"

mkdir -p "$PROC_DIR" "$ARCHIVE_DIR"

json_escape() {
    # Escapa para caber dentro de uma string JSON (usado só no campo 'detail' da auditoria).
    local s=$1
    s=${s//\\/\\\\}
    s=${s//\"/\\\"}
    s=${s//$'\n'/\\n}
    printf '%s' "$s"
}

audit() {  # $1=event $2=request_id $3=detail_json (já pronto, ex: '{"a":1}')
    printf '{"ts":"%s","event":"%s","request_id":"%s","detail":%s}\n' \
        "$(date -u +%FT%TZ)" "$1" "$2" "$3" >> "$LOG"
}

html_escape() {
    local s=$1
    s=${s//&/&amp;}
    s=${s//</&lt;}
    s=${s//>/&gt;}
    printf '%s' "$s"
}

telegram_call() {  # $1=método $2...=--data-urlencode args
    local method=$1; shift
    curl -fsS -X POST "$API/$method" "$@"
}

answer_toast() {  # $1=callback_query_id $2=texto
    telegram_call answerCallbackQuery \
        --data-urlencode "callback_query_id=$1" \
        --data-urlencode "text=$2" \
        --data-urlencode "show_alert=true" > /dev/null || true
}

edit_final_text() {  # $1=request_id $2=sufixo de status humano-legível
    local id="$1" suffix="$2" msg_id
    msg_id="$(grep -m1 '^msg_id=' "$STATE_DIR/${id}.state" | cut -d= -f2-)"
    [ -n "$msg_id" ] || return 0
    telegram_call editMessageReplyMarkup \
        --data-urlencode "chat_id=${TELEGRAM_CHAT_ID}" \
        --data-urlencode "message_id=${msg_id}" \
        --data-urlencode 'reply_markup={"inline_keyboard":[]}' > /dev/null || true
    telegram_call sendMessage \
        --data-urlencode "chat_id=${TELEGRAM_CHAT_ID}" \
        --data-urlencode "reply_to_message_id=${msg_id}" \
        --data-urlencode "text=($suffix)" > /dev/null || true
}

send_notification() {  # $1=request_id — pedido já está em PROC_DIR
    local id="$1" cmd reason host requested_by text kb resp msg_id
    cmd="$(grep -m1 '^command_b64=' "$PROC_DIR/$id" | cut -d= -f2- | base64 -d)"
    reason="$(grep -m1 '^reason_b64=' "$PROC_DIR/$id" | cut -d= -f2- | base64 -d)"
    host="$(grep -m1 '^host=' "$PROC_DIR/$id" | cut -d= -f2-)"
    requested_by="$(grep -m1 '^requested_by=' "$PROC_DIR/$id" | cut -d= -f2-)"

    # Newline real (não '%0A'): --data-urlencode escapa o '%' literal, então '%0A' chegaria ao
    # Telegram como o texto "%0A" em vez de virar quebra de linha.
    text="⚠️ <b>Escalação de privilégio solicitada</b>"$'\n'
    text+="host: $(html_escape "$host")"$'\n'
    text+="usuário: $(html_escape "$requested_by")"$'\n'
    text+="motivo: $(html_escape "$reason")"$'\n'
    text+="<pre><code>$(html_escape "$cmd")</code></pre>"

    kb='{"inline_keyboard":[['
    kb+='{"text":"✅ Permitir","callback_data":"allow:'"$id"'"},'
    kb+='{"text":"❌ Negar","callback_data":"deny:'"$id"'"},'
    kb+='{"text":"⏸ Adiar","callback_data":"defer:'"$id"'"}'
    kb+=']]}'

    # 'if resp=$(...)' em vez de 'resp=$(...)' solto: sob 'set -e', uma atribuição simples aborta
    # o script inteiro se o comando falhar — e falha aqui é esperado (ex.: texto acima do limite de
    # ~4096 caracteres do Telegram para 'text', API fora do ar). Precisamos capturar isso e negar
    # fail-closed em vez de derrubar o daemon (que reprocessaria o mesmo pedido em loop no restart).
    if resp="$(telegram_call sendMessage \
        --data-urlencode "chat_id=${TELEGRAM_CHAT_ID}" \
        --data-urlencode "parse_mode=HTML" \
        --data-urlencode "text=$text" \
        --data-urlencode "reply_markup=$kb")"; then
        :
    else
        audit notify_failed "$id" "{\"host\":\"$(json_escape "$host")\",\"requested_by\":\"$(json_escape "$requested_by")\"}"
        write_response "$id" error "" "" "subot-gate: falha ao notificar o aprovador via Telegram (comando/motivo grande demais para uma mensagem, ou API indisponível) — negado (fail-closed)."
        return 0
    fi
    msg_id="$(jq -r '.result.message_id' <<<"$resp")"

    {
        printf 'status=pending\n'
        printf 'deferred=0\n'
        printf 'msg_id=%s\n' "$msg_id"
        printf 'deadline=%s\n' "$(( $(date +%s) + TIMEOUT_SECONDS ))"
    } > "$STATE_DIR/${id}.state"
    audit notified "$id" "{\"host\":\"$(json_escape "$host")\",\"requested_by\":\"$(json_escape "$requested_by")\",\"command\":\"$(json_escape "$cmd")\",\"reason\":\"$(json_escape "$reason")\"}"
}

write_response() {  # $1=id $2=status $3=exit_code $4=stdout $5=stderr
    local id="$1" tmp="$RESP_DIR/.tmp.$$.${1}"
    {
        printf 'status=%s\n' "$2"
        printf 'exit_code=%s\n' "${3:-}"
        printf 'stdout_b64=%s\n' "$(printf '%s' "${4:-}" | base64 -w0)"
        printf 'stderr_b64=%s\n' "$(printf '%s' "${5:-}" | base64 -w0)"
    } > "$tmp"
    # UMask=0077 do serviço faz '> "$tmp"' sair 0600 root:root — 'subot' (não é root, é só membro
    # do grupo 'subot-gate') não conseguiria ler a própria resposta sem isto. 0640 + grupo
    # 'subot-gate' é a permissão mínima que casa com o 0710 (só '--x') de var/responses: dá pra
    # abrir por nome exato (sem listar), mas não escrever nem sobrescrever.
    chmod 0640 "$tmp"
    chgrp subot-gate "$tmp"
    mv -- "$tmp" "$RESP_DIR/$id"
    sed -i 's/^status=.*/status=resolved/' "$STATE_DIR/${id}.state" 2>/dev/null || true
    mv -- "$PROC_DIR/$id" "$ARCHIVE_DIR/$id" 2>/dev/null || true
}

execute_approved() {  # $1=request_id $2=decided_by_id (numérico)
    local id="$1" decided_by="$2"
    (
        local cmd out err ec errfile
        cmd="$(grep -m1 '^command_b64=' "$PROC_DIR/$id" | cut -d= -f2- | base64 -d)"
        errfile="$(mktemp)"
        out="$(bash -c "$cmd" 2>"$errfile")"
        ec=$?
        err="$(cat "$errfile")"
        rm -f "$errfile"
        write_response "$id" approved "$ec" "$out" "$err"
        audit executed "$id" "{\"exit_code\":$ec,\"decided_by\":$decided_by}"
    ) &
}

handle_callback() {  # $1=update json (contém .callback_query)
    local upd="$1" from_id chat_id cq_id data action id
    from_id="$(jq -r '.callback_query.from.id' <<<"$upd")"
    chat_id="$(jq -r '.callback_query.message.chat.id' <<<"$upd")"
    cq_id="$(jq -r '.callback_query.id' <<<"$upd")"
    data="$(jq -r '.callback_query.data' <<<"$upd")"
    action="${data%%:*}"
    id="${data#*:}"

    if [ "$chat_id" != "$TELEGRAM_CHAT_ID" ] || ! grep -qw "$from_id" <<<"${TELEGRAM_AUTHORIZED_IDS//,/ }"; then
        answer_toast "$cq_id" "Não autorizado"
        audit unauthorized_attempt "$id" "{\"from_id\":$from_id,\"chat_id\":$chat_id}"
        return
    fi

    if [ ! -f "$STATE_DIR/${id}.state" ]; then
        answer_toast "$cq_id" "Solicitação desconhecida ou já arquivada"
        return
    fi
    if ! grep -q '^status=pending' "$STATE_DIR/${id}.state"; then
        answer_toast "$cq_id" "Esta solicitação já foi resolvida"
        return
    fi

    case "$action" in
        allow)
            # Transição de status síncrona, ANTES de qualquer chamada de rede (edit_final_text) ou
            # de forkar a execução: fecha duas janelas de corrida ao mesmo tempo —
            # (1) duplo-clique em "Permitir" chegando no mesmo lote do getUpdates executaria o
            #     comando aprovado duas vezes, já que só o fim do job em background (potencialmente
            #     minutos depois) atualizava o status antes;
            # (2) check_timeouts só olha 'status=pending' — um comando aprovado perto do fim do
            #     TIMEOUT_SECONDS que demora pra rodar (ex.: apt-get upgrade) seria marcado
            #     "expirado sem resposta" por cima da aprovação real, e o cliente veria "negado"
            #     apesar do humano ter aprovado e do comando já ter executado.
            # A partir daqui 'status' não é mais 'pending', então o check no topo desta função
            # (linha ~161) já barra um segundo clique, e check_timeouts (que só age em 'pending')
            # ignora este pedido pelo resto da execução.
            sed -i 's/^status=.*/status=approved/' "$STATE_DIR/${id}.state"
            answer_toast "$cq_id" "Aprovado — executando"
            edit_final_text "$id" "aprovado por ${from_id}"
            execute_approved "$id" "$from_id"
            ;;
        deny)
            answer_toast "$cq_id" "Negado"
            edit_final_text "$id" "negado por ${from_id}"
            write_response "$id" denied "" "" ""
            audit denied "$id" "{\"decided_by\":$from_id}"
            ;;
        defer)
            sed -i 's/^deferred=.*/deferred=1/' "$STATE_DIR/${id}.state"
            answer_toast "$cq_id" "Adiado — os botões continuam válidos, decida quando quiser"
            audit deferred "$id" "{\"deferred_by\":$from_id}"
            ;;
        *)
            answer_toast "$cq_id" "Ação desconhecida"
            ;;
    esac
}

check_timeouts() {
    local now sf id deadline
    now="$(date +%s)"
    for sf in "$STATE_DIR"/*.state; do
        [ -e "$sf" ] || continue
        grep -q '^status=pending' "$sf" || continue
        grep -q '^deferred=1' "$sf" && continue
        deadline="$(grep -m1 '^deadline=' "$sf" | cut -d= -f2-)"
        id="$(basename "$sf" .state)"
        if [ "$now" -ge "$deadline" ]; then
            write_response "$id" timeout "" "" ""
            edit_final_text "$id" "expirado sem resposta — negado automaticamente"
            audit timeout "$id" "{}"
        fi
    done
}

purge_old() {
    find "$ARCHIVE_DIR" "$RESP_DIR" -maxdepth 1 -type f -mtime "+${PURGE_AFTER_DAYS}" -delete 2>/dev/null || true
    find "$STATE_DIR" -maxdepth 1 -name '*.state' -mtime "+${PURGE_AFTER_DAYS}" -delete 2>/dev/null || true
}

reconcile_on_startup() {
    local f id
    for f in "$REQ_DIR"/*; do
        [ -e "$f" ] || continue
        id="$(basename "$f")"
        mv -- "$f" "$PROC_DIR/$id"
    done
    for f in "$PROC_DIR"/*; do
        [ -e "$f" ] || continue
        id="$(basename "$f")"
        [ -f "$RESP_DIR/$id" ] && continue
        [ -f "$STATE_DIR/${id}.state" ] || send_notification "$id"
    done
}

touch "$OFFSET_FILE" 2>/dev/null || echo 0 > "$OFFSET_FILE"
reconcile_on_startup
last_purge=0

while true; do
    for f in "$REQ_DIR"/*; do
        [ -e "$f" ] || continue
        id="$(basename "$f")"
        mv -- "$f" "$PROC_DIR/$id"
        send_notification "$id"
    done

    offset="$(cat "$OFFSET_FILE" 2>/dev/null || echo 0)"
    if updates="$(curl -fsS "$API/getUpdates?timeout=15&offset=${offset}&allowed_updates=%5B%22callback_query%22%5D")"; then
        :
    else
        # getUpdates falhou (rede, API fora do ar, token inválido): evita spin/martelar a API —
        # o 'timeout=15' do long-poll só protege o caminho feliz, não o de erro.
        updates='{"result":[]}'
        sleep 5
    fi
    while IFS= read -r row; do
        [ -n "$row" ] || continue
        update_id="$(jq -r '.update_id' <<<"$row")"
        echo "$(( update_id + 1 ))" > "$OFFSET_FILE"
        if jq -e '.callback_query' >/dev/null 2>&1 <<<"$row"; then
            handle_callback "$row"
        fi
    done < <(jq -c '.result[]?' <<<"$updates")

    check_timeouts

    now="$(date +%s)"
    if [ "$(( now - last_purge ))" -ge 3600 ]; then
        purge_old
        last_purge="$now"
    fi
done
