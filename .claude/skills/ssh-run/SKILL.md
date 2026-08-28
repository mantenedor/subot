---
name: ssh-run
description: Executa comandos vetados em um host ou grupo de hosts do inventário subot com segurança (allowlist + confirmação), usando o MCP server ssh_connector. Use quando o pedido for para rodar algo em um host gerenciado.
---

# ssh-run

1. Confirme o host ou grupo alvo com `mcp__inventory_connector__list_hosts` se houver dúvida.
2. Rode o comando com `mcp__ssh_connector__ssh_exec`.
3. Se a resposta for "CONFIRMAÇÃO NECESSÁRIA", explique ao operador humano o comando, o host e o
   motivo da confirmação (risco `sensitive`/`destructive`), peça o aceite explícito, e só então
   rode novamente `ssh_exec` com o `confirm_token` retornado.
4. Se a resposta for "BLOQUEADO", pare — não existe caminho de contorno, é um padrão proibido por
   política (`config/policy/destructive_patterns.yaml`).
5. Resuma stdout/stderr relevantes de volta para o operador; não cole saídas gigantes sem
   necessidade.
