---
name: scan-subot-dependencies
description: Varre as dependências do próprio subot (pacotes Python de packages/subot_core e packages/subot_orchestrator, e imagens Docker do docker-compose.yml/containers/) em busca de CVEs conhecidas, e registra achados em data/security-findings/subot.jsonl. Use quando o pedido for para verificar vulnerabilidades no código/imagens do próprio subot, não em hosts gerenciados.
---

# scan-subot-dependencies

Varredura **somente-leitura** de SCA (software composition analysis) no próprio projeto — nunca
faz `pip install`/atualiza `requirements.txt` sem pedido explícito à parte.

1. **Dependências Python:** para cada `requirements*.txt`/`pyproject.toml` sob
   `packages/subot_core/` e `packages/subot_orchestrator/`, rode `pip-audit -r <arquivo>` se
   `pip-audit` estiver disponível (`command -v pip-audit`). Se não estiver instalado, informe isso
   como uma lacuna (não instale silenciosamente um pacote novo no ambiente sem avisar) e ofereça
   rodar `pip install --user pip-audit` só com confirmação explícita.
2. **Imagens Docker:** extraia as tags de imagem referenciadas em `docker-compose.yml` e em
   qualquer `containers/*/Dockerfile` (linhas `FROM`). Se `trivy` estiver disponível
   (`command -v trivy`), rode `trivy image --severity HIGH,CRITICAL <imagem>` para cada uma. Sem
   `trivy`, reporte a lacuna do mesmo jeito que no passo anterior.
3. Para cada achado, verifique em `data/security-findings/subot.jsonl` se já foi registrado antes
   sem resolução — só destaque como "novo" o que ainda não constava.
4. Registre uma linha JSON por rodada de varredura (append-only):
   ```json
   {"ts": "<ISO8601 UTC>", "scope": "python|docker", "target": "<arquivo-ou-imagem>", "findings": [{"id": "<CVE>", "package": "<nome>", "severity": "<critical|high|medium|low>", "fixed_in": "<versão-ou-null>"}], "recommendation": "<texto objetivo>"}
   ```
5. Resuma priorizando `critical`/`high` primeiro, e separando claramente achados em dependências
   Python vs. imagens Docker.
6. Recomendações de correção (bump de versão, troca de imagem base) ficam só como **texto** aqui —
   qualquer alteração real em `requirements.txt`/`Dockerfile`/`docker-compose.yml` é uma mudança de
   código normal do projeto (edite e commit como qualquer outra), não algo que este skill aplique
   sozinho.
