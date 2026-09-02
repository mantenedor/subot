#!/usr/bin/env bash
# Instalador de um comando só do gate de escalação de privilégio, pra rodar NO HOST GERENCIADO
# (não no bastião):
#
#   export SUBOT_BASTION_PUBKEY="$(cat secrets/ssh/bastion_id_ed25519.pub)"   # no bastião, copie o valor
#   curl -fsSL https://raw.githubusercontent.com/mantenedor/subot/main/managed-host-gate/install.sh | sudo bash
#
# Diferente do install.sh da raiz (que sobe uma stack Docker isolada e por isso é silencioso por
# padrão), este mexe em contas reais do host — cria o usuário 'subot', grava a chave pública do
# bastião em authorized_keys, mexe em sudoers. install-gate.sh (chamado no final deste script)
# narra cada uma dessas ações e pede confirmação antes de executar; ver SUBOT_GATE_ASSUME_YES se
# precisar automatizar sem terminal interativo.
#
# Variáveis de ambiente:
#   SUBOT_BASTION_PUBKEY   conteúdo de secrets/ssh/bastion_id_ed25519.pub do bastião (obrigatório
#                          sem terminal; com terminal, cai num prompt se não for definida)
#   SUBOT_REPO_RAW_BASE    base para baixar os arquivos quando rodando via curl|bash
#                          (default: https://raw.githubusercontent.com/mantenedor/subot)
#   SUBOT_REPO_REF         branch/tag (default: main)
#   SUBOT_GATE_ASSUME_YES  1 = não pede confirmação em nenhum passo (só pra automação consciente)
set -euo pipefail

REPO_RAW_BASE="${SUBOT_REPO_RAW_BASE:-https://raw.githubusercontent.com/mantenedor/subot}"
REPO_REF="${SUBOT_REPO_REF:-main}"
BASE_URL="${REPO_RAW_BASE}/${REPO_REF}/managed-host-gate"

log() { printf '==> %s\n' "$1"; }

if [ "$(id -u)" -ne 0 ]; then
    echo "rode como root: curl ... | sudo bash   (ou baixe o arquivo e rode com sudo)" >&2
    exit 1
fi

# Se este arquivo tiver bin/ e install-gate.sh do lado (checkout local, ex.: dentro do repo
# clonado), usa os arquivos daqui e não baixa nada. Só baixa quando de fato rodando via 'curl | bash'
# (BASH_SOURCE aponta pra um script sem os arquivos-irmãos por perto, ou nem existe — stdin de um
# pipe).
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-}")" 2>/dev/null && pwd)" || SCRIPT_DIR=""
if [ -n "$SCRIPT_DIR" ] && [ -f "$SCRIPT_DIR/install-gate.sh" ] && [ -f "$SCRIPT_DIR/bin/subot-gate-daemon.sh" ]; then
    log "checkout local detectado em $SCRIPT_DIR — usando os arquivos daqui, sem baixar nada"
    WORKDIR="$SCRIPT_DIR"
else
    log "rodando via curl|bash — baixando os arquivos necessários de $BASE_URL"
    WORKDIR="$(mktemp -d)"
    trap 'rm -rf "$WORKDIR"' EXIT
    for f in install-gate.sh bin/subot-gate-daemon.sh bin/subot-gate-request.sh \
             etc/telegram.env.example systemd/subot-gate.service; do
        mkdir -p "$WORKDIR/$(dirname "$f")"
        curl -fsSL "$BASE_URL/$f" -o "$WORKDIR/$f"
    done
    chmod +x "$WORKDIR"/bin/*.sh "$WORKDIR"/install-gate.sh
fi

cd "$WORKDIR"
# 'exec' (não 'source'/chamada simples) e SEM redirecionar stdin: um 'curl | bash' tem o pipe
# como stdin do processo bash inteiro — install-gate.sh lê todo prompt de /dev/tty explicitamente
# por causa disso, nunca de stdin puro (que já está ocupado pelo conteúdo baixado).
exec bash install-gate.sh
