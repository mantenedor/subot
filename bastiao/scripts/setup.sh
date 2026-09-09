#!/usr/bin/env bash
# Setup de primeira execução: cria diretórios de dados persistidos, gera .env (se ausente) e o
# par de chaves SSH do próprio bastião (se ausente). Seguro para rodar de novo — nunca sobrescreve
# segredos já existentes.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

mkdir -p ../data/guac-db ../data/guac-recordings ../data/audit ../data/agent-home ../data/ollama-models ../data/security-findings
mkdir -p secrets/ssh
mkdir -p containers/guacamole/initdb
mkdir -p ../backups
mkdir -p ../domain

# O container 'agent' roda como UID 1000 (usuário 'subot') — diretórios que ele precisa escrever
# (home, modelos do Ollama, auditoria, achados de varredura de vulnerabilidade) precisam pertencer
# a esse UID quando criados pela primeira vez como root no host, senão a montagem bind fica de
# fato somente-leitura pra esse usuário.
chown -R 1000:1000 ../data/agent-home ../data/ollama-models ../data/audit ../data/security-findings 2>/dev/null || true

if [ ! -f .env ]; then
    echo "==> criando .env a partir de .env.example"
    cp .env.example .env
    GUACDB_PASS="$(openssl rand -base64 24 | tr -d '=+/')"
    if [[ "${OSTYPE:-}" == "darwin"* ]]; then
        sed -i '' "s/^GUACDB_PASSWORD=.*/GUACDB_PASSWORD=${GUACDB_PASS}/" .env
    else
        sed -i "s/^GUACDB_PASSWORD=.*/GUACDB_PASSWORD=${GUACDB_PASS}/" .env
    fi
    echo "    GUACDB_PASSWORD aleatório gerado em .env"
else
    echo "==> .env já existe, mantendo como está"
fi

echo "==> domain/ pronto (vazio até o primeiro host — use a skill 'onboard-host' para adicionar um; ver domain/README.md)"

KEY="secrets/ssh/bastion_id_ed25519"
if [ ! -f "$KEY" ]; then
    echo "==> gerando par de chaves SSH do bastião (protegida por passphrase) em $KEY"
    GENERATED_SSH_PASSPHRASE="$(openssl rand -base64 24 | tr -d '=+/')"
    ssh-keygen -t ed25519 -f "$KEY" -N "$GENERATED_SSH_PASSPHRASE" -C "subot-bastion"
    chmod 600 "$KEY"
    chmod 644 "${KEY}.pub"
    # se secrets/ssh pertence a root (setup rodando no host) e o binário existir, concede leitura
    # pro UID 1000 (container 'agent') via ACL, sem abrir grupo/outros — chmod sozinho não resolve
    # sem abrir grupo/outros. Se o diretório já pertence ao próprio UID 1000, redundante; pula sem
    # quebrar o script.
    if command -v setfacl >/dev/null 2>&1; then
        setfacl -m u:1000:r "$KEY" || true
    fi
    echo ""
    echo "    #################################################################"
    echo "    # GUARDE ESTA PASSPHRASE AGORA — ela NÃO é salva em nenhum arquivo."
    echo "    # Sem ela, a chave privada não abre (mesmo com o arquivo em mãos)."
    echo "    #"
    echo "    #   ${GENERATED_SSH_PASSPHRASE}"
    echo "    #"
    echo "    # Se estiver rodando este script sozinho (fora do install.sh), exporte antes do"
    echo "    # 'docker compose up':"
    echo "    #   export SUBOT_SSH_KEY_PASSPHRASE='${GENERATED_SSH_PASSPHRASE}'"
    echo "    #################################################################"
    echo ""
    echo "    adicione ${KEY}.pub ao authorized_keys de cada host gerenciado"
else
    echo "==> par de chaves SSH do bastião já existe, mantendo como está"
fi

if [ ! -f ../ia/policy/managed-identity.json ]; then
    echo "==> criando ia/policy/managed-identity.json a partir do template (injetando ${KEY}.pub)"
    python3 -c '
import json, sys
with open("../ia/policy/managed-identity.json.example", encoding="utf-8") as f:
    data = json.load(f)
with open(sys.argv[1], encoding="utf-8") as f:
    data["ssh_authorized_key"] = f.read().strip()
with open("../ia/policy/managed-identity.json", "w", encoding="utf-8") as f:
    json.dump(data, f, indent=2, ensure_ascii=False)
    f.write("\n")
' "${KEY}.pub"
    echo "    lista 'sudoers' padrão copiada do template — edite ia/policy/managed-identity.json"
    echo "    depois para promover/remover comandos (efetivo só após 'subot identity sync --host <nome>')."
else
    echo "==> ia/policy/managed-identity.json já existe, mantendo como está"
fi

touch secrets/ssh/known_hosts

CONSOLE_KEY="secrets/ssh/guac_console_ed25519"
if [ ! -f "$CONSOLE_KEY" ]; then
    echo "==> gerando par de chaves do console SSH (Guacamole -> container agent, via rede docker)"
    # Sem passphrase de propósito: essa chave só abre uma sessão dropbear que só existe dentro da
    # rede subot_net (nunca publicada no host) e cujo alcance já é limitado a "quem consegue
    # autenticar no Guacamole e abrir essa conexão" — diferente da chave do bastião, que sai pra
    # infraestrutura gerenciada de verdade e por isso é protegida por passphrase.
    ssh-keygen -t ed25519 -f "$CONSOLE_KEY" -N "" -C "subot-guac-console"
    chmod 600 "$CONSOLE_KEY"
    chmod 644 "${CONSOLE_KEY}.pub"
    echo "    chave pronta — use ia/mcp/remote_desktop_connector para criar a conexão no"
    echo "    Guacamole (host 'subot-console' -> agent:2222, ver domain/README.md)"
else
    echo "==> chave do console SSH já existe, mantendo como está"
fi

if [ ! -f containers/guacamole/initdb/01-initdb.sql ]; then
    echo "==> gerando schema do banco do Guacamole"
    docker run --rm guacamole/guacamole:1.5.5 /opt/guacamole/bin/initdb.sh --postgresql \
        > containers/guacamole/initdb/01-initdb.sql
else
    echo "==> schema do Guacamole já gerado, mantendo como está"
fi

echo "==> setup concluído. Próximos passos:"
echo "    1. docker compose up -d"
echo "    2. bash scripts/pull-models.sh   (depois do container 'agent' estar de pé)"
echo "    3. Guacamole fica em http://<IP-desta-VM>:8080/guacamole/ (HTTP, sem TLS — ver README"
echo "       sobre o trade-off de segurança dessa porta)."
