---
name: ssh-run
description: Executa comandos vetados em um host ou grupo de hosts do inventário subot com segurança (allowlist + confirmação), usando o MCP server ssh_connector. Use quando o pedido for para rodar algo em um host gerenciado.
---

# ssh-run

1. Confirme o host ou grupo alvo com `mcp__inventory_connector__list_hosts` se houver dúvida.
2. Rode o comando com `mcp__ssh_connector__ssh_exec`.
3. Se a resposta for "MOTIVO NECESSÁRIO", o comando é `sensitive`/`destructive` — formule um
   `reason` curto e claro (por que esse comando precisa rodar agora) e rode `ssh_exec` de novo com
   os MESMOS argumentos mais `reason=...`. A partir daí a escalação é real, não um token
   autosservível: se o comando já estiver pré-aprovado no sudoers deste host, executa na hora; se
   não, bloqueia esperando um humano aprovar em tempo real (Gate/Telegram no host) — isso pode
   levar até ~5 minutos, é esperado, não é erro. Avise o operador que está esperando aprovação se a
   chamada demorar.
4. Se a resposta for "BLOQUEADO", pare — não existe caminho de contorno, é um padrão proibido por
   política (`config/policy/destructive_patterns.yaml`), nunca executa mesmo com aprovação humana.
5. Resuma stdout/stderr relevantes de volta para o operador; não cole saídas gigantes sem
   necessidade.
