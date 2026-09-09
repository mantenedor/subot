---
name: scan-host-vulnerabilities
description: Varre hosts gerenciados (config/hosts.yaml) em busca de atualizações de segurança/CVEs conhecidas nos pacotes instalados, e registra achados em data/security-findings/hosts.jsonl. Use quando o pedido for para verificar vulnerabilidades, CVEs ou pendências de patch nos hosts gerenciados.
---

# scan-host-vulnerabilities

Varredura **somente-leitura** de vulnerabilidades conhecidas em pacotes de SO — nunca instala nem
atualiza nada sem confirmação/gate explícito à parte.

1. Liste os hosts alvo via `config/hosts.yaml` (ou `mcp__inventory_connector__list_hosts` quando
   disponível). Sem alvo explícito do usuário, varra todos os hosts SSH do inventário.
2. Para cada host, detecte a família de SO antes de escolher o comando (`cat /etc/os-release`).
   Rode só comandos de **leitura/consulta** (classificados `safe` por `policy.py` — nunca
   `upgrade`/`install` de verdade):
   - RHEL/Rocky/Alma/Fedora (`dnf`): `dnf updateinfo list security --available 2>&1`
   - Debian/Ubuntu (`apt`): `apt list --upgradable 2>/dev/null` +
     `apt-get -s dist-upgrade 2>/dev/null | grep -i security`
   - Se `trivy` ou `grype` já estiverem instalados no host, prefira
     `trivy fs --scanners vuln --severity HIGH,CRITICAL /` (mais preciso que o gerenciador de
     pacotes) — mas nunca instale essas ferramentas num host gerenciado sem pedir confirmação
     primeiro (é uma mudança de estado no host).
   - Hosts `protected`/`prod` (tag em `hosts.yaml`): mesmo sendo comandos `safe`, redobre a atenção
     ao relatar — a política já eleva o risco desses hosts (ver `packages/subot_core/subot_core/policy.py`).
3. Para cada achado (advisory ID/CVE, pacote, severidade), verifique em
   `data/security-findings/hosts.jsonl` se esse mesmo achado já foi registrado **para este host**
   numa varredura anterior sem ter sido resolvido — evita ficar re-alertando o mesmo item já
   conhecido a cada rodada; só destaque como "novo" o que não estava lá antes.
4. Registre uma linha JSON por host varrido (append, nunca sobrescreva o arquivo), mesmo sem
   achados (evidência de que a varredura rodou):
   ```json
   {"ts": "<ISO8601 UTC>", "host": "<nome-em-hosts.yaml>", "os": "<id do os-release>", "findings": [{"id": "<CVE-ou-advisory>", "package": "<nome>", "severity": "<critical|high|medium|low>"}], "recommendation": "<texto objetivo>"}
   ```
5. Produza um resumo humano ao final, priorizado por severidade e por hosts `protected`/`prod`
   primeiro — não apenas despeje o JSON bruto na conversa.
6. Se um achado indicar necessidade de patch, **não aplique nada aqui** — recomende a ação (ex.:
   "rodar `dnf upgrade <pacote>` no host X, exige o gate de escalação de privilégio se o host tiver
   `managed-host-gate` instalado") e deixe a execução para uma ação separada e confirmada.
