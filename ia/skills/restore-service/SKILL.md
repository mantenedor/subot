---
name: restore-service
description: Restaura um serviço containerizado a partir de um backup recebido via rsync/SSH em um host de backup dedicado (dados sob /mnt/backup), subindo o container equivalente em um host gerenciado ao lado de uma instância já existente da mesma tecnologia — seguindo um runbook já testado por tecnologia em vez de improvisar. Use quando o pedido for para restaurar, recuperar ou subir um backup de um serviço como container.
---

# restore-service

1. Identifique origem e destino: host de backup + caminho exato sob `/mnt/backup/<cliente>/...`
   (app dir e volumes normalmente ficam em subpastas separadas, ex.: `opt/<serviço>_og/` e
   `volumes/`), e o host de destino onde o container deve subir — tipicamente ao lado de uma
   instância já rodando da mesma tecnologia (mesma imagem base, mesma topologia de volumes).

2. Procure um runbook testado para a tecnologia em `ia/skills/restore-service/runbooks/
   <tecnologia>/` antes de agir. Runbooks conhecidos hoje:
   - `generic/fixar-imagem-base.md` — sempre aplicável, qualquer stack Docker restaurada.
   - `otrs-znuny/limpar-cache-loader-pos-restore.md` — cache de template/loader/assets.
   - `otrs-znuny/eliminar-ldap-stale-pos-restore.md` — auth/sync LDAP apontando pro ambiente
     antigo.

   Se não existir runbook para a tecnologia em questão, diga isso explicitamente ao operador antes
   de improvisar os passos equivalentes — não finja que existe cobertura testada que não existe.

3. Antes de mover qualquer dado, confirme com o operador: nome do serviço/container de destino
   (não pode colidir com o serviço irmão já em produção), caminho de destino no host, rede/portas,
   e o método de transferência dos dados do host de backup até o host de destino. Essas decisões
   afetam um host de produção — não decida sozinho, confirme.

4. Siga `generic/fixar-imagem-base.md` primeiro: identifique a tag exata da imagem usada pela
   instância irmã já rodando (`docker inspect <container> --format '{{.Config.Image}}'`) e fixe a
   mesma tag para o container restaurado, nunca `latest`.

5. Transfira o app dir e os volumes preservando estrutura; valide tamanho/contagem de arquivos no
   destino contra a origem antes de considerar a transferência completa.

6. **Suba o container sem iniciar o processo/daemon da aplicação**, a menos que o operador peça
   explicitamente para colocá-lo no ar — isso permite validar montagens e permissões, e aplicar as
   correções pós-restauração do runbook (cache stale, auth/config herdada do ambiente antigo)
   antes de expor o serviço. Normalmente isso significa sobrescrever o entrypoint/comando do
   container (ex.: `sleep infinity` ou um shell) em vez de rodar o comando padrão da imagem.

7. Depois do primeiro boot, aplique as correções pós-restauração específicas da tecnologia
   documentadas no(s) runbook(s) relevante(s) antes de considerar a restauração validada.

8. Ao final, resuma para o operador: o que subiu, o que ainda está pendente (ex.: daemon não
   iniciado de propósito) e qual o próximo passo manual para colocar o serviço restaurado no ar.
