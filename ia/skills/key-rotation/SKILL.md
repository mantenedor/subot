---
name: key-rotation
description: Rotaciona o par de chaves SSH do bastião (e orienta a atualização de authorized_keys nos hosts gerenciados) usando scripts/rotate-ssh-keys.sh. Use quando o pedido for sobre rotação, renovação ou comprometimento de chaves SSH.
---

# key-rotation

1. Rode `bash scripts/rotate-ssh-keys.sh` — gera um novo par em `./secrets/ssh/` com sufixo de
   data, mantendo o par anterior até confirmação manual de que os hosts foram atualizados.
2. Para cada host afetado, atualizar `authorized_keys` remotamente é uma ação **sensível**: use a
   skill `ssh-run` normalmente, o que vai exigir confirmação explícita por host.
3. Só remova a chave antiga de `./secrets/ssh/` depois de validar que todos os hosts do grupo
   afetado aceitam a nova chave (`ssh_exec` com um comando trivial como `whoami`).
4. O log de auditoria (automático via `subot_core.audit`) registra qual chave/host foi usado em
   cada execução — nunca apague chaves antigas sem essa validação.
