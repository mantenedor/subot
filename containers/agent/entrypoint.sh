#!/bin/sh
set -eu

echo "[subot-agent] iniciando..."

SSH_DIR="${SUBOT_SSH_DIR:-/opt/subot/secrets/ssh}"
mkdir -p "${SUBOT_AUDIT_DIR:-/opt/subot/data/audit}"
# secrets/ssh é montado somente-leitura neste container — 'touch' aqui é só best-effort (o
# arquivo já devia existir, criado por scripts/setup.sh no host); nunca deve derrubar o container.
touch "$SSH_DIR/known_hosts" 2>/dev/null || true

if [ -f "$SSH_DIR/bastion_id_ed25519" ]; then
    perm=$(stat -c "%a" "$SSH_DIR/bastion_id_ed25519" 2>/dev/null || echo "600")
    case "$perm" in
        600|400) ;;
        *) echo "[subot-agent] AVISO: $SSH_DIR/bastion_id_ed25519 tem permissao $perm (esperado 600). Rode 'chmod 600' no host." ;;
    esac
    if ! ssh-keygen -y -P '' -f "$SSH_DIR/bastion_id_ed25519" >/dev/null 2>&1; then
        if [ -z "${SUBOT_SSH_KEY_PASSPHRASE:-}" ]; then
            echo "[subot-agent] AVISO: a chave do bastiao esta protegida por passphrase mas SUBOT_SSH_KEY_PASSPHRASE nao foi definida — operacoes SSH vao falhar ate voce exportar essa variavel e subir a stack de novo."
        fi
    fi
else
    echo "[subot-agent] AVISO: nenhuma chave do bastiao em $SSH_DIR/bastion_id_ed25519 — rode scripts/setup.sh no host primeiro."
fi

# Console SSH do agent, só pela rede docker interna (subot_net) — sem porta publicada no host,
# autenticação só por chave (dropbear -s desliga login por senha). A chave pública vem de
# secrets/ssh/guac_console_ed25519.pub (gerada por scripts/setup.sh); a privada correspondente é
# o que o Guacamole usa pra abrir a sessão (ver mcp-servers/remote_desktop_connector).
mkdir -p /home/subot/.ssh
chmod 700 /home/subot/.ssh
if [ -f "$SSH_DIR/guac_console_ed25519.pub" ]; then
    cp "$SSH_DIR/guac_console_ed25519.pub" /home/subot/.ssh/authorized_keys
    chmod 600 /home/subot/.ssh/authorized_keys
    HOST_KEY=/home/subot/.ssh/dropbear_ed25519_host_key
    if [ ! -f "$HOST_KEY" ]; then
        dropbearkey -t ed25519 -f "$HOST_KEY" >/dev/null 2>&1
    fi
    echo "[subot-agent] iniciando console SSH em background (dropbear, porta 2222, só pela rede docker)"
    dropbear -F -E -p 2222 -r "$HOST_KEY" -s &
else
    echo "[subot-agent] AVISO: secrets/ssh/guac_console_ed25519.pub nao encontrada — console SSH nao iniciado. Rode scripts/setup.sh no host primeiro."
fi

mkdir -p "${OLLAMA_MODELS:-/home/subot/.ollama}"
echo "[subot-agent] iniciando Ollama em background (127.0.0.1:11434)"
ollama serve &

echo "[subot-agent] iniciando API REST em background (porta 8081)"
(cd /opt/subot && exec uvicorn app.main:app --host 0.0.0.0 --port 8081) &

echo "[subot-agent] pronto. Servidores MCP registrados em .claude/settings.json; CLI do orquestrador disponivel como 'subot'."
exec "$@"
