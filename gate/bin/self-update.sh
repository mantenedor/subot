#!/usr/bin/env bash
# Atualiza o daemon do gate (bin/subot-gate-daemon.sh + systemd/subot-gate.service) neste host a
# partir de um host de referência via scp direto root-a-root (sem passar pelo próprio gate — evita
# o daemon reiniciar a si mesmo no meio da própria execução aprovada). Roda neste host gerenciado,
# como root, com acesso SSH root direto ao host de referência já configurado.
#
# Idempotente por hash: só instala/reinicia se o conteúdo buscado for diferente do já instalado.
# Protótipo para uma futura feature de auto-update do gate entre hosts — ver
# docs/ARCHITECTURE.md e a memória do projeto sobre isso antes de generalizar.
set -euo pipefail

SRC_HOST="${SRC_HOST:-compose}"
SRC_USER="${SRC_USER:-root}"
SRC_DAEMON="${SRC_DAEMON:-/opt/subot/gate/bin/subot-gate-daemon.sh}"
SRC_SERVICE="${SRC_SERVICE:-/opt/subot/gate/systemd/subot-gate.service}"
DST_DAEMON=/opt/subot-gate/bin/subot-gate-daemon.sh
DST_SERVICE=/etc/systemd/system/subot-gate.service

[ "$(id -u)" -eq 0 ] || { echo "rode como root" >&2; exit 1; }

tmp_daemon="$(mktemp)"
tmp_service="$(mktemp)"
trap 'rm -f "$tmp_daemon" "$tmp_service"' EXIT

echo "==> buscando versão de referência em ${SRC_USER}@${SRC_HOST}"
scp -q "${SRC_USER}@${SRC_HOST}:${SRC_DAEMON}" "$tmp_daemon"
scp -q "${SRC_USER}@${SRC_HOST}:${SRC_SERVICE}" "$tmp_service"

cur_daemon_hash="$(md5sum "$DST_DAEMON" 2>/dev/null | cut -d' ' -f1 || true)"
new_daemon_hash="$(md5sum "$tmp_daemon" | cut -d' ' -f1)"
cur_service_hash="$(md5sum "$DST_SERVICE" 2>/dev/null | cut -d' ' -f1 || true)"
new_service_hash="$(md5sum "$tmp_service" | cut -d' ' -f1)"

if [ "$cur_daemon_hash" = "$new_daemon_hash" ] && [ "$cur_service_hash" = "$new_service_hash" ]; then
    echo "==> já está na versão de referência (daemon ${new_daemon_hash}, service ${new_service_hash}) — nada a fazer."
    exit 0
fi

echo "==> mudança detectada (daemon ${cur_daemon_hash:-ausente} -> ${new_daemon_hash}, service ${cur_service_hash:-ausente} -> ${new_service_hash}) — aplicando atualização."

if [ -f /opt/subot-gate/etc/telegram.env ] && [ ! -f /opt/subot-gate/etc/.env ]; then
    echo "==> migrando /opt/subot-gate/etc/telegram.env -> .env"
    mv /opt/subot-gate/etc/telegram.env /opt/subot-gate/etc/.env
fi

install -m 0700 -o root -g root "$tmp_daemon" "$DST_DAEMON"
install -m 0644 -o root -g root "$tmp_service" "$DST_SERVICE"
systemctl daemon-reload
systemctl restart subot-gate.service
sleep 2
echo "==> status pós-atualização:"
systemctl is-active subot-gate.service
systemctl show subot-gate.service -p NRestarts
journalctl -u subot-gate -n 15 --no-pager
