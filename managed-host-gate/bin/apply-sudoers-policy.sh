#!/usr/bin/env bash
# Aplica (ou só mostra, com --dry-run) a política de identidade/sudoers de 'subot' NO HOST
# GERENCIADO. Roda como root — chamado direto por install-gate.sh (instalação inicial, dentro do
# 'confirm()' interativo já existente) ou pelo daemon do gate (subot-gate-daemon.sh::execute_approved,
# depois de aprovação humana via Telegram) para mudanças posteriores num host já provisionado.
# NUNCA editar /etc/sudoers.d/subot-agent à mão — este script é a única fonte de verdade de como
# esse arquivo é gerado, e sempre reescreve do zero (idempotente, nunca faz append incremental).
#
# Uso: apply-sudoers-policy.sh [--dry-run] <payload-json-base64>
#
# Payload esperado (montado no bastião — por scripts/setup.sh + install-gate.sh na instalação
# inicial, ou por 'subot identity sync' depois — já MESCLADO: este script não sabe nem precisa
# saber a distinção "lista padrão vs. lista por-host", só recebe o estado final desejado):
#   {
#     "username": "subot",
#     "sudoers": [{"pattern": "systemctl restart *"}, ...],
#     "destructive_patterns": ["systemctl stop *", ...],  # checagem de defesa em profundidade —
#     "blocked_patterns": ["rm -rf /", ...]                # só padrões glob puro (sem 're:'); os
#   }                                                        # regex são checados só no bastião.
set -euo pipefail

DRY_RUN=0
if [ "${1:-}" = "--dry-run" ]; then
    DRY_RUN=1
    shift
fi
PAYLOAD_B64="${1:?uso: apply-sudoers-policy.sh [--dry-run] <payload-json-base64>}"

if [ "$(id -u)" -ne 0 ]; then
    echo "apply-sudoers-policy: precisa rodar como root." >&2
    exit 1
fi
command -v jq >/dev/null 2>&1 || { echo "apply-sudoers-policy: jq é obrigatório." >&2; exit 1; }
command -v visudo >/dev/null 2>&1 || { echo "apply-sudoers-policy: visudo é obrigatório." >&2; exit 1; }

PAYLOAD_JSON="$(printf '%s' "$PAYLOAD_B64" | base64 -d)"

USERNAME="$(jq -r '.username // empty' <<<"$PAYLOAD_JSON")"
[ -n "$USERNAME" ] || { echo "apply-sudoers-policy: payload sem 'username'." >&2; exit 1; }

# Arrays podem vir vazios — mapfile ainda assim declara a variável (0 elementos), mas
# "${arr[@]}" sobre array vazio sob 'set -u' já deu erro em bash < 4.4; ':-' evita esse caso.
mapfile -t DESTRUCTIVE < <(jq -r '.destructive_patterns[]? // empty' <<<"$PAYLOAD_JSON")
mapfile -t BLOCKED     < <(jq -r '.blocked_patterns[]? // empty' <<<"$PAYLOAD_JSON")

matches_any() {  # $1=candidato, resto=padrões glob (case/glob do bash, não fnmatch, mas equivalente aqui)
    local candidate="$1" pat; shift
    for pat in "$@"; do
        case "$candidate" in
            $pat) return 0 ;;
        esac
    done
    return 1
}

TMP_SUDOERS="$(mktemp)"
trap 'rm -f "$TMP_SUDOERS"' EXIT

{
    echo "# Gerenciado inteiramente por managed-host-gate/bin/apply-sudoers-policy.sh — NUNCA edite à mão."
    echo "# Toda alteração passa pela instalação inicial (managed-host-gate/install-gate.sh) ou pelo"
    echo "# Gate (aprovação humana via Telegram, 'subot identity sync'), com o conteúdo completo"
    echo "# revalidado por 'visudo -c' antes de ser ativado. Editar manualmente é sobrescrito na"
    echo "# próxima aplicação."
    echo "# Gerado em: $(date -u +%FT%TZ)"
} > "$TMP_SUDOERS"

# @base64 (em vez de extrair '.pattern' cru linha a linha) preserva com segurança um pattern que
# em si contenha uma quebra de linha embutida — texto cru quebraria o pareamento 1-pattern-por-
# linha do mapfile, disfarçando a segunda metade como se fosse OUTRO pattern e escapando da
# checagem de injeção logo abaixo. Uma chamada de jq só, não uma por padrão.
mapfile -t PATTERNS_B64 < <(jq -r '.sudoers[].pattern | @base64' <<<"$PAYLOAD_JSON")
PATTERN_COUNT="${#PATTERNS_B64[@]}"
PROMOTED=0
for PATTERN_B64 in "${PATTERNS_B64[@]:-}"; do
    [ -n "$PATTERN_B64" ] || continue
    PATTERN="$(base64 -d <<<"$PATTERN_B64")"
    # Normaliza espaços/tabs repetidos para um espaço só ANTES de qualquer checagem — evita que um
    # espaçamento irregular (ex.: "systemctl  stop nginx", dois espaços) escape do match glob
    # contra destructive_patterns (que espera um espaço exato) enquanto ainda vira uma regra de
    # sudoers funcional na prática.
    PATTERN="$(printf '%s' "$PATTERN" | tr -s '[:blank:]' ' ')"

    # Uma quebra de linha embutida no pattern permitiria forjar uma SEGUNDA diretiva de sudoers
    # inteira dentro de "$REST" (linha ~93) — 'visudo -c' valida sintaxe linha a linha e aceitaria
    # a diretiva forjada sem reclamar. Recusa explícita antes de qualquer outra checagem.
    if [[ "$PATTERN" == *$'\n'* ]]; then
        echo "apply-sudoers-policy: RECUSADO '$PATTERN' — contém quebra de linha, não pode virar uma única diretiva de sudoers." >&2
        continue
    fi
    if [[ "$PATTERN" == re:* ]]; then
        echo "apply-sudoers-policy: RECUSADO '$PATTERN' — padrão regex ('re:') não tem tradução em sudoers, só glob." >&2
        continue
    fi
    if matches_any "$PATTERN" "${DESTRUCTIVE[@]:-}"; then
        echo "apply-sudoers-policy: RECUSADO '$PATTERN' — corresponde a um padrão destructive, nunca promovido." >&2
        continue
    fi
    if matches_any "$PATTERN" "${BLOCKED[@]:-}"; then
        echo "apply-sudoers-policy: RECUSADO '$PATTERN' — corresponde a um padrão blocked, nunca promovido." >&2
        continue
    fi

    BIN="${PATTERN%% *}"
    RESOLVED="$(command -v "$BIN" 2>/dev/null || true)"
    if [ -z "$RESOLVED" ]; then
        echo "apply-sudoers-policy: RECUSADO '$PATTERN' — binário '$BIN' não encontrado neste host (command -v falhou)." >&2
        continue
    fi

    REST="${PATTERN#"$BIN"}"
    printf '%s ALL=(root) NOPASSWD: %s%s\n' "$USERNAME" "$RESOLVED" "$REST" >> "$TMP_SUDOERS"
    PROMOTED=$((PROMOTED + 1))
done

echo ""
echo "==> $PROMOTED de $PATTERN_COUNT padrões promovidos para '$USERNAME'."
echo "--- conteúdo gerado ---"
cat "$TMP_SUDOERS"
echo "-----------------------"

if [ "$DRY_RUN" -eq 1 ]; then
    echo "==> --dry-run: nada foi instalado."
    exit 0
fi

if ! visudo -c -f "$TMP_SUDOERS" >/dev/null; then
    echo "apply-sudoers-policy: sudoers gerado é INVÁLIDO (visudo -c falhou) — abortando, /etc/sudoers.d/subot-agent NÃO foi tocado." >&2
    exit 1
fi

install -m 0440 -o root -g root "$TMP_SUDOERS" /etc/sudoers.d/subot-agent
echo "==> /etc/sudoers.d/subot-agent atualizado e validado (visudo -c)."
