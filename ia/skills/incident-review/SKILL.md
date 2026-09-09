---
name: incident-review
description: Reúne o log de auditoria e gravações de sessão do Guacamole de uma janela de tempo para investigar um incidente. Use quando o pedido for para investigar, revisar ou explicar o que aconteceu em um período específico.
---

# incident-review

1. Delimite a janela de tempo (ISO 8601) e, se souber, o host/ator envolvido.
2. Consulte `mcp__audit_connector__query_audit_log` com `since`/`until` e, se fizer sentido,
   `event` para filtrar (`ssh_exec`, `add_host`, `guac_create_connection`, etc.).
3. Destaque especialmente entradas com `status=blocked` ou `status=confirmation_required` sem uma
   execução correspondente logo depois — indicam uma ação que foi tentada mas não concluída
   dentro da política.
4. Para sessões RDP/VNC no período, cite que a gravação correspondente está em
   `./data/guac-recordings` e pode ser reproduzida a partir da própria UI do Guacamole (histórico
   de conexões).
5. Produza um resumo cronológico, não apenas uma lista bruta de eventos.
