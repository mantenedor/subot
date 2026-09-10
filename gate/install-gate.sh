#!/usr/bin/env bash
# Instala o gate de escalação de privilégio NO HOST GERENCIADO (roda como root, ali, não no
# bastião). Idempotente — pode rodar de novo sem duplicar nada. Papel equivalente a
# scripts/setup.sh do bastião, mas para o host remoto. Normalmente chamado por install.sh (o
# entrypoint pensado para 'curl | bash'), mas pode ser rodado direto se já houver um checkout
# local (bin/, etc/, systemd/ ao lado deste arquivo).
#
# Identidade (usuário, chave pública, sudoers pré-aprovado) vem de um manifesto JSON — ver
# ia/policy/managed-identity.json.example no repositório. Exporte SUBOT_IDENTITY_JSON_B64 com
# o conteúdo (base64) de ia/policy/managed-identity.json do bastião antes de rodar este script;
# opcionalmente SUBOT_HOST_IDENTITY_JSON_B64 com o complemento específico deste host
# (domain/.../<hostname>/role.json), se existir. SUBOT_BASTION_PUBKEY (só a chave, formato
# antigo) continua aceito como fallback depreciado se SUBOT_IDENTITY_JSON_B64 não vier.
#
# Migração assumida: o usuário 'subotsu' (sudo NOPASSWD) deixa de existir totalmente. Depois deste
# script, o único usuário do subot no host é o do manifesto (default 'subot'), sem sudo nenhum a
# menos do que esteja explicitamente no manifesto de identidade — todo o resto da escalação de
# privilégio passa por este gate.
#
# Cada ação que muda estado real do host (usuário, sudoers, authorized_keys, pacotes, serviço) é
# anunciada e confirmada antes de rodar — diferente do install.sh da raiz (que é silencioso por
# padrão porque só mexe em containers Docker isolados), este mexe em contas reais de um host de
# produção. Sem terminal interativo, recusa prosseguir a menos que SUBOT_GATE_ASSUME_YES=1 seja
# definido conscientemente (mesma filosofia de "falhar rápido" do install.sh: nunca ficar
# pendurado esperando um 'read' que nunca chega num pipe não-interativo).
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

# '[ -r /dev/tty ]' NÃO basta: checa só a permissão do arquivo especial, não se existe de fato um
# terminal controlador — retorna "true" mesmo sem tty nenhum, e cada 'read ... < /dev/tty' real
# falharia depois com ENXIO. Tentar abrir de verdade é o único jeito confiável.
have_tty() { { true < /dev/tty; } 2>/dev/null; }

confirm() {  # $1 = descrição da ação. 0=segue, 1=pular (chamador decide se pular é fatal).
    local desc="$1" ans
    echo ""
    echo "==> $desc"
    if ! have_tty; then
        if [ "${SUBOT_GATE_ASSUME_YES:-}" = "1" ]; then
            echo "    (sem terminal interativo — prosseguindo, SUBOT_GATE_ASSUME_YES=1)"
            return 0
        fi
        echo "    sem terminal interativo e SUBOT_GATE_ASSUME_YES não definido — abortando." >&2
        echo "    rode com um terminal de verdade, ou exporte SUBOT_GATE_ASSUME_YES=1 conscientemente." >&2
        exit 1
    fi
    read -r -p "    prosseguir? [Enter]=sim, s=pular este passo : " ans < /dev/tty
    if [ "${ans:-}" = "s" ]; then
        echo "    pulado."
        return 1
    fi
    return 0
}

confirm_destructive() {  # mesmo espírito, mas exige digitar 'yes' — para o passo do subotsu.
    local desc="$1" ans
    echo ""
    echo "==> $desc"
    if ! have_tty; then
        if [ "${SUBOT_GATE_ASSUME_YES:-}" = "1" ]; then
            echo "    (sem terminal interativo — prosseguindo, SUBOT_GATE_ASSUME_YES=1)"
            return 0
        fi
        echo "    ação irreversível sem terminal interativo — abortando (ver SUBOT_GATE_ASSUME_YES)." >&2
        exit 1
    fi
    read -r -p "    digite 'yes' para confirmar (qualquer outra coisa pula este passo): " ans < /dev/tty
    if [ "$ans" != "yes" ]; then
        echo "    pulado."
        return 1
    fi
    return 0
}

if [ "$(id -u)" -ne 0 ]; then
    echo "rode como root: sudo ./install-gate.sh" >&2
    exit 1
fi

# --- 1. dependências ----------------------------------------------------------------------------
# Movido para o início: os passos seguintes (usuário, chave) já precisam de 'jq' pra ler o
# manifesto de identidade.
MISSING=()
for bin in curl jq flock base64 od; do
    command -v "$bin" >/dev/null 2>&1 || MISSING+=("$bin")
done
if [ "${#MISSING[@]}" -gt 0 ]; then
    if confirm "instalar dependências ausentes via apt-get: ${MISSING[*]}"; then
        apt-get update -qq && apt-get install -y -qq "${MISSING[@]}"
    else
        echo "sem estas dependências o gate não funciona: ${MISSING[*]}" >&2
        exit 1
    fi
else
    echo "==> dependências (curl, jq, flock, base64, od) já presentes"
fi

# --- 2. manifesto de identidade (usuário, chave, sudoers) ---------------------------------------
IDENTITY_JSON="{}"
if [ -n "${SUBOT_IDENTITY_JSON_B64:-}" ]; then
    IDENTITY_JSON="$(printf '%s' "$SUBOT_IDENTITY_JSON_B64" | base64 -d)" || {
        echo "SUBOT_IDENTITY_JSON_B64 não decodifica como base64 válido." >&2
        exit 1
    }
fi
HOST_IDENTITY_JSON="{}"
if [ -n "${SUBOT_HOST_IDENTITY_JSON_B64:-}" ]; then
    HOST_IDENTITY_JSON="$(printf '%s' "$SUBOT_HOST_IDENTITY_JSON_B64" | base64 -d)" || {
        echo "SUBOT_HOST_IDENTITY_JSON_B64 não decodifica como base64 válido." >&2
        exit 1
    }
fi
IDENTITY_USERNAME="$(jq -r '.username // "subot"' <<<"$IDENTITY_JSON")"
IDENTITY_PUBKEY="$(jq -r '.ssh_authorized_key // empty' <<<"$IDENTITY_JSON")"
echo "==> identidade: usuário '$IDENTITY_USERNAME'$([ "$IDENTITY_JSON" = "{}" ] && echo " (manifesto não fornecido — usando default)")"

# --- 3. usuário -----------------------------------------------------------------------------
if ! id "$IDENTITY_USERNAME" >/dev/null 2>&1; then
    if confirm "criar usuário de sistema '$IDENTITY_USERNAME' (useradd --create-home --shell /bin/bash $IDENTITY_USERNAME)"; then
        useradd --create-home --shell /bin/bash "$IDENTITY_USERNAME"
    else
        echo "sem o usuário '$IDENTITY_USERNAME' não há como continuar." >&2
        exit 1
    fi
else
    echo "==> usuário '$IDENTITY_USERNAME' já existe, mantendo"
fi

# --- 4. chave pública do bastião em ~<usuário>/.ssh/authorized_keys -----------------------------
PUBKEY="$IDENTITY_PUBKEY"
if [ -z "$PUBKEY" ] && [ -n "${SUBOT_BASTION_PUBKEY:-}" ]; then
    echo "==> usando SUBOT_BASTION_PUBKEY (formato antigo) — prefira SUBOT_IDENTITY_JSON_B64"
    echo "    (ver ia/policy/managed-identity.json.example no repositório)."
    PUBKEY="$SUBOT_BASTION_PUBKEY"
fi
if [ -z "$PUBKEY" ] && have_tty; then
    echo ""
    echo "==> nenhuma chave pública fornecida (SUBOT_IDENTITY_JSON_B64/SUBOT_BASTION_PUBKEY)"
    echo "    cole o conteúdo de secrets/ssh/bastion_id_ed25519.pub (do bastião) e pressione Enter:"
    read -r PUBKEY < /dev/tty
fi
if [ -z "$PUBKEY" ]; then
    echo "sem a chave pública do bastião não há como autenticar '$IDENTITY_USERNAME' — defina SUBOT_IDENTITY_JSON_B64 ou SUBOT_BASTION_PUBKEY." >&2
    exit 1
fi
USER_HOME="$(getent passwd "$IDENTITY_USERNAME" | cut -d: -f6)"
if confirm "gravar a chave pública do bastião em ${USER_HOME}/.ssh/authorized_keys"; then
    install -d -o "$IDENTITY_USERNAME" -g "$IDENTITY_USERNAME" -m 0700 "${USER_HOME}/.ssh"
    touch "${USER_HOME}/.ssh/authorized_keys"
    grep -qxF "$PUBKEY" "${USER_HOME}/.ssh/authorized_keys" || printf '%s\n' "$PUBKEY" >> "${USER_HOME}/.ssh/authorized_keys"
    chmod 0600 "${USER_HOME}/.ssh/authorized_keys"
    chown "$IDENTITY_USERNAME:$IDENTITY_USERNAME" "${USER_HOME}/.ssh/authorized_keys"
fi

# --- 5. grupo + diretórios/permissões -----------------------------------------------------------
if confirm "criar grupo 'subot-gate' (só '$IDENTITY_USERNAME' como membro) e os diretórios do gate em /opt/subot-gate"; then
    groupadd -f subot-gate
    usermod -aG subot-gate "$IDENTITY_USERNAME"

    # /opt/subot-gate precisa de 'x' de grupo para '$IDENTITY_USERNAME' conseguir ATRAVESSAR até
    # var/requests — 'x' sem 'r' permite entrar em subdiretório por nome mas não listar o conteúdo
    # daqui (não vê 'bin'/'etc' via 'ls'), e bin/ e etc/ continuam 0700 root:root, inacessíveis
    # mesmo por nome.
    install -d -o root -g subot-gate -m 0710 /opt/subot-gate
    install -d -o root -g root       -m 0700 /opt/subot-gate/bin
    install -d -o root -g root       -m 0700 /opt/subot-gate/etc
    install -d -o root -g subot-gate -m 0710 /opt/subot-gate/var
    # sticky (+t) + 'rwx' de grupo sem 'r': grava/cria sem listar (drop-box).
    install -d -o root -g subot-gate -m 1730 /opt/subot-gate/var/requests
    # sem 'r'/'w' de grupo, só 'x': abre por nome exato (o request_id que 'subot' mesmo gerou), não lista.
    install -d -o root -g subot-gate -m 0710 /opt/subot-gate/var/responses
    install -d -o root -g root       -m 0700 /opt/subot-gate/var/state
    install -d -o root -g root       -m 0700 /opt/subot-gate/var/state/processing
    install -d -o root -g root       -m 0700 /opt/subot-gate/var/state/archive
    install -d -o root -g root       -m 0700 /opt/subot-gate/var/log
else
    echo "sem os diretórios do gate não há como continuar." >&2
    exit 1
fi

# --- 6. scripts -----------------------------------------------------------------------------------
if confirm "instalar os scripts do gate (daemon, cliente, aplicador de sudoers)"; then
    install -m 0700 -o root -g root bin/subot-gate-daemon.sh /opt/subot-gate/bin/subot-gate-daemon.sh
    install -m 0700 -o root -g root bin/apply-sudoers-policy.sh /opt/subot-gate/bin/apply-sudoers-policy.sh
    install -m 0755 -o root -g root bin/subot-gate-request.sh /usr/local/bin/subot-gate-request
else
    echo "sem os scripts instalados não há como continuar." >&2
    exit 1
fi

# --- 7. sudoers pré-aprovado (padrão + específico deste host, se veio) --------------------------
MERGED_SUDOERS="$(jq -n --argjson a "$(jq '.sudoers // []' <<<"$IDENTITY_JSON")" \
                        --argjson b "$(jq '.sudoers // []' <<<"$HOST_IDENTITY_JSON")" \
                        '$a + $b')"
SUDOERS_COUNT="$(jq 'length' <<<"$MERGED_SUDOERS")"
if [ "$SUDOERS_COUNT" -gt 0 ]; then
    APPLY_PAYLOAD="$(jq -n --arg u "$IDENTITY_USERNAME" --argjson s "$MERGED_SUDOERS" '{username: $u, sudoers: $s}')"
    APPLY_PAYLOAD_B64="$(printf '%s' "$APPLY_PAYLOAD" | base64 -w0)"
    echo ""
    echo "==> pré-visualização do sudoers a aplicar para '$IDENTITY_USERNAME' ($SUDOERS_COUNT padrão(ões) no manifesto):"
    /opt/subot-gate/bin/apply-sudoers-policy.sh --dry-run "$APPLY_PAYLOAD_B64" || true
    if confirm "aplicar de fato o sudoers acima (grava /etc/sudoers.d/subot-agent, validado com visudo -c)"; then
        /opt/subot-gate/bin/apply-sudoers-policy.sh "$APPLY_PAYLOAD_B64"
    else
        echo "    sudoers não aplicado agora — '$IDENTITY_USERNAME' segue sem essas entradas (100% via Gate"
        echo "    até aplicar manualmente ou rodar 'subot identity sync' depois)."
    fi
else
    echo "==> nenhum padrão de sudoers no manifesto de identidade — '$IDENTITY_USERNAME' segue sem"
    echo "    nenhuma entrada de sudo (toda escalação passa 100% pelo Gate)."
fi

# --- 8. credenciais do Telegram -------------------------------------------------------------------
# Passo interativo por natureza (não há como "digitar" token/chat_id sem terminal) — diferente dos
# outros blocos, SUBOT_GATE_ASSUME_YES sem tty não tenta ler nada: vai direto pro template, sem
# travar num 'read' que nunca teria como ser respondido.
if [ -f /opt/subot-gate/etc/telegram.env ] && [ ! -f /opt/subot-gate/etc/.env ]; then
    echo "==> migrando /opt/subot-gate/etc/telegram.env -> .env (mesmo conteúdo/permissões)"
    mv /opt/subot-gate/etc/telegram.env /opt/subot-gate/etc/.env
fi
if [ ! -f /opt/subot-gate/etc/.env ]; then
    if have_tty && confirm "configurar credenciais do Telegram agora (token, chat_id, IDs autorizados)"; then
        read -r -p "    TELEGRAM_BOT_TOKEN: " TG_TOKEN < /dev/tty
        read -r -p "    TELEGRAM_CHAT_ID: " TG_CHAT < /dev/tty
        read -r -p "    TELEGRAM_AUTHORIZED_IDS (separados por vírgula, obrigatório se for um grupo): " TG_IDS < /dev/tty
        echo "    confirme: chat_id=${TG_CHAT}, authorized_ids=${TG_IDS}, token=${TG_TOKEN:0:6}...(oculto)"
        read -r -p "    gravar? [Enter]=sim, s=pular : " ans < /dev/tty
        if [ "${ans:-}" != "s" ]; then
            install -m 0600 -o root -g root /dev/null /opt/subot-gate/etc/.env
            {
                printf 'TELEGRAM_BOT_TOKEN=%s\n' "$TG_TOKEN"
                printf 'TELEGRAM_CHAT_ID=%s\n' "$TG_CHAT"
                printf 'TELEGRAM_AUTHORIZED_IDS=%s\n' "$TG_IDS"
                printf 'TIMEOUT_SECONDS=300\n'
                printf 'TELEGRAM_API_BASE=https://api.telegram.org\n'
            } > /opt/subot-gate/etc/.env
        else
            install -m 0600 -o root -g root etc/.env.example /opt/subot-gate/etc/.env
            echo "    template gravado sem preencher — edite /opt/subot-gate/etc/.env manualmente."
        fi
    else
        install -m 0600 -o root -g root etc/.env.example /opt/subot-gate/etc/.env
        echo "    template gravado — edite /opt/subot-gate/etc/.env manualmente antes de iniciar o serviço."
    fi
else
    echo "==> /opt/subot-gate/etc/.env já existe, mantendo"
fi
chmod 0600 /opt/subot-gate/etc/.env
chown root:root /opt/subot-gate/etc/.env

# --- 9. systemd -----------------------------------------------------------------------------------
if confirm "instalar e habilitar o serviço systemd 'subot-gate'"; then
    install -m 0644 -o root -g root systemd/subot-gate.service /etc/systemd/system/subot-gate.service
    systemctl daemon-reload
    systemctl enable subot-gate.service
else
    echo "sem o serviço habilitado o gate não roda — instale manualmente depois." >&2
fi

# --- 10. migração: remover subotsu/sudoers legado (irreversível) -----------------------------------
if confirm_destructive "revogar sudo de '$IDENTITY_USERNAME' (fora do manifesto) e desativar 'subotsu' (modelo antigo) — IRREVERSÍVEL sem reconfigurar manualmente"; then
    rm -f /etc/sudoers.d/subotsu
    if id subotsu >/dev/null 2>&1; then
        usermod -L -s /usr/sbin/nologin subotsu
        echo "    usuário 'subotsu' desativado (login bloqueado, shell nologin) — remova com"
        echo "    'userdel -r subotsu' manualmente quando tiver certeza que nada mais depende dele."
    fi
    rm -f /etc/sudoers.d/subot
else
    echo "    'subotsu'/sudoers antigos mantidos como estavam — o gate convive com eles por enquanto,"
    echo "    mas isso reabre o caminho de escalação que ele existe para fechar."
fi

echo ""
echo "==> instalação concluída. Se .env não foi preenchido acima, edite"
echo "    /opt/subot-gate/etc/.env e rode: systemctl start subot-gate"
echo "    Depois valide com: sudo -l -U ${IDENTITY_USERNAME}   (mostra só o que estiver no manifesto)"
