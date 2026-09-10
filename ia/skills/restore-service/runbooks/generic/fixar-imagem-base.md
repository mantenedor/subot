# Docker: fixar imagem base ao restaurar um serviço a partir de backup

## Objetivo

Ao migrar/restaurar um serviço containerizado (volumes/dados via `rsync` ou similar) em um novo
host, evitar que a nova VM puxe uma versão diferente da imagem base e quebre dependências de
biblioteca do SO da imagem — mesmo com os dados de aplicação intactos.

Aplicável a qualquer stack docker compose restaurada em host/versão de Docker diferente da
origem, não só ao caso de origem deste procedimento.

## Sintoma típico

Container sobe ou falha ao iniciar com erro de biblioteca ausente/incompatível do SO da imagem
(ex: `libpcre.so.3` ausente ao trocar a imagem base do Apache), mesmo que os volumes de dados
tenham sido restaurados corretamente.

## Procedimento

1. Identificar a tag/versão exata da imagem usada no ambiente de origem (`docker inspect
   <container> --format '{{.Config.Image}}'` ou o `Dockerfile`/`docker-compose.yml` original, se
   disponível).
2. Fixar essa mesma tag no `Dockerfile`/compose do novo ambiente em vez de usar `latest` ou uma
   tag mais recente:
   ```dockerfile
   FROM httpd:2.4.61
   ```
3. Rebuild/recriar o container com a imagem fixada.
4. Só depois de eliminar essa variável, seguir para outras hipóteses (permissão, cache de
   aplicação, rede) — não investigar em paralelo.

## Checklist de descarte: permissão/UID-GID/volume

Antes de suspeitar de bloqueio de filesystem, UID/GID ou montagem de volume, validar:

1. Usuário e grupo do processo dentro do container (ex: Apache rodando como `www-data:www-data`).
2. UID/GID do usuário de aplicação (ex: `uid=1000`, `gid=33`) e se ele pertence ao grupo do
   processo do container.
3. Caminho real do volume no host (`docker volume inspect <volume>` → `/var/lib/docker/volumes/
   <volume>/_data`).
4. Teste de escrita direto como o usuário do processo no diretório afetado (ex: `su www-data -c
   "touch /opt/app/var/tmp/teste"` dentro do container).

Se a escrita funciona, o problema **não** é permissão/UID/GID/volume — descartar essa hipótese e
olhar para cache de aplicação ou configuração antes de mexer em permissões.
