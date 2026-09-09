#!/usr/bin/env bash
# Teste funcional (não unitário) de bin/apply-sudoers-policy.sh — precisa rodar como root (usa
# 'sudo' aqui só pra chamar o script com privilégio; ele mesmo decide o que fazer) e exige jq +
# visudo no PATH. Não roda em CI hoje (nenhum runner com esses pré-requisitos garantidos) — é para
# rodar manualmente antes de confiar no script contra um host real (ver docs/ARCHITECTURE.md,
# Guia de operação). Não mexe em nada fora de /etc/sudoers.d/subot-agent, sempre limpo no final.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

SCRIPT="bin/apply-sudoers-policy.sh"
SUDOERS_FILE="/etc/sudoers.d/subot-agent"
PASS=0
FAIL=0

command -v jq >/dev/null 2>&1 || { echo "SKIP: jq não instalado — não dá pra rodar este teste aqui." >&2; exit 0; }
command -v visudo >/dev/null 2>&1 || export PATH="$PATH:/usr/sbin"
command -v visudo >/dev/null 2>&1 || { echo "SKIP: visudo não encontrado — não dá pra rodar este teste aqui." >&2; exit 0; }
[ "$(id -u)" -eq 0 ] || SUDO="sudo env PATH=$PATH"
: "${SUDO:=}"

check() {  # $1=descrição $2=exit_code_esperado $3=grep_esperado_na_saída $4=payload_json
    local desc="$1" expected_ec="$2" expect_grep="$3" payload_json="$4" b64 out ec
    b64="$(printf '%s' "$payload_json" | base64 -w0)"
    if out="$($SUDO bash "$SCRIPT" --dry-run "$b64" 2>&1)"; then ec=0; else ec=$?; fi
    if [ "$ec" -ne "$expected_ec" ]; then
        echo "FALHOU: $desc — exit code $ec, esperado $expected_ec" >&2
        echo "$out" >&2
        FAIL=$((FAIL + 1))
        return
    fi
    if [ -n "$expect_grep" ] && ! grep -qF "$expect_grep" <<<"$out"; then
        echo "FALHOU: $desc — saída não contém '$expect_grep'" >&2
        echo "$out" >&2
        FAIL=$((FAIL + 1))
        return
    fi
    echo "OK: $desc"
    PASS=$((PASS + 1))
}

check "recusa padrão regex" 0 "não tem tradução em sudoers" \
    '{"username":"t","sudoers":[{"pattern":"re:^kill -[0-9]+ .*"}]}'

check "recusa padrão destructive" 0 "corresponde a um padrão destructive" \
    '{"username":"t","sudoers":[{"pattern":"git push origin main"}],"destructive_patterns":["git push*"]}'

check "recusa padrão blocked" 0 "corresponde a um padrão blocked" \
    '{"username":"t","sudoers":[{"pattern":"rm -rf /"}],"blocked_patterns":["rm -rf /"]}'

check "recusa binário inexistente" 0 "não encontrado neste host" \
    '{"username":"t","sudoers":[{"pattern":"binario-que-nao-existe-xyz --foo"}]}'

check "promove padrão válido com path resolvido" 0 "ALL=(root) NOPASSWD: /usr/bin/cat" \
    '{"username":"t","sudoers":[{"pattern":"cat /var/log/*"}]}'

check "recusa pattern com quebra de linha embutida (injeção de diretiva forjada)" 0 "quebra de linha" \
    '{"username":"t","sudoers":[{"pattern":"cat /var/log/*\nsubot ALL=(ALL) NOPASSWD: ALL"}]}'

check "normaliza espaço duplo antes de checar contra destructive_patterns" 0 "corresponde a um padrão destructive" \
    '{"username":"t","sudoers":[{"pattern":"git  push origin main"}],"destructive_patterns":["git push*"]}'

# --- aplicação real: instala, valida com visudo -c de verdade, limpa depois -----------------
echo ""
echo "--- aplicação real (não --dry-run) ---"
PAYLOAD='{"username":"testuser-subot-gate-test","sudoers":[{"pattern":"cat /var/log/*"}]}'
B64="$(printf '%s' "$PAYLOAD" | base64 -w0)"
if $SUDO bash "$SCRIPT" "$B64" >/tmp/apply-sudoers-test.out 2>&1 \
    && $SUDO test -f "$SUDOERS_FILE" \
    && $SUDO grep -q "testuser-subot-gate-test" "$SUDOERS_FILE" \
    && $SUDO visudo -c >/dev/null 2>&1; then
    echo "OK: instala de verdade e visudo -c aceita o resultado"
    PASS=$((PASS + 1))
else
    echo "FALHOU: aplicação real não instalou um sudoers.d válido" >&2
    cat /tmp/apply-sudoers-test.out >&2
    FAIL=$((FAIL + 1))
fi
$SUDO rm -f "$SUDOERS_FILE"

# --- payload inválido (username com espaço gera linha malformada) nunca deve tocar o arquivo ---
PAYLOAD_BAD='{"username":"nome com espaco","sudoers":[{"pattern":"cat /var/log/*"}]}'
B64_BAD="$(printf '%s' "$PAYLOAD_BAD" | base64 -w0)"
if $SUDO bash "$SCRIPT" "$B64_BAD" >/tmp/apply-sudoers-test-bad.out 2>&1; then
    echo "FALHOU: payload malformado deveria ter sido rejeitado por visudo -c (exit 0 inesperado)" >&2
    FAIL=$((FAIL + 1))
elif $SUDO test -f "$SUDOERS_FILE"; then
    echo "FALHOU: visudo -c rejeitou mas o arquivo ativo foi tocado mesmo assim" >&2
    FAIL=$((FAIL + 1))
else
    echo "OK: visudo -c inválido aborta sem tocar o arquivo ativo"
    PASS=$((PASS + 1))
fi
rm -f /tmp/apply-sudoers-test.out /tmp/apply-sudoers-test-bad.out

echo ""
echo "==> $PASS passou, $FAIL falhou."
[ "$FAIL" -eq 0 ]
