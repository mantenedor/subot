---
name: backup-restore
description: Faz backup ou restauração dos volumes persistidos do subot (config, dados de auditoria, banco do Guacamole, chaves) usando scripts/backup.sh e scripts/restore.sh. Use quando o pedido envolver backup, restore, ou recuperação de desastre do próprio subot.
---

# backup-restore

- Backup: rode `bash scripts/backup.sh` (a partir da raiz do projeto, no host ou dentro do
  container `subot-agent-1`). Gera um `.tar.gz` versionado por timestamp em `./backups/`, cobrindo
  `./data`, `.env`, `config/hosts.yaml` e `./secrets` (chaves SSH, TLS, credencial do proxy) — é o
  backup completo de tudo que o repositório git *não* contém (ver README, "Repositório vs. dados
  de ambiente"). Use `--exclude-secrets` só se for transportar o arquivo por um canal onde prefere
  não incluir material criptográfico; nesse caso o backup sozinho não é suficiente para restaurar
  acesso SSH/TLS numa VM nova.
- Restore: rode `bash scripts/restore.sh <arquivo.tar.gz>`. **Ação destrutiva** — sempre confirme
  com o operador humano antes de rodar, e prefira parar a stack (`docker compose down`) antes de
  restaurar para evitar escrita concorrente.
- Nunca restaure por cima de dados de produção sem antes confirmar que existe um backup do estado
  atual.
- **A passphrase da chave SSH do bastião nunca está no backup** (nunca é persistida em arquivo
  nenhum, de propósito). Antes de tratar um backup como "completo", confirme com o operador humano
  que ele guardou essa passphrase em algum lugar durável (gerenciador de senhas, cofre da
  organização) — sem ela, a chave restaurada fica permanentemente inutilizável e a única saída é
  gerar uma chave nova e redistribuir a pública para todos os hosts gerenciados.
