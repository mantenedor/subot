# OTRS/Znuny: limpar cache e loader após restaurar/migrar instância

## Objetivo

Resolver erros de minificação/JavaScript e interface quebrada em uma instância OTRS/Znuny
restaurada a partir de backup em outro ambiente, quando o cache de template/loader trazido junto
com os dados não é compatível com o novo host.

## Sintoma

Interface web carrega parcialmente ou com erros de JavaScript/CSS após restaurar os volumes de uma
instância OTRS/Znuny em novo ambiente (nova VM, novo host Docker, etc.), mesmo com os dados de
aplicação corretos.

## Procedimento

Executar dentro do container/host da aplicação, na ordem:

```bash
docker exec -u root otrs rm -rf /opt/otrs/var/tmp/*
docker exec -u root otrs /opt/otrs/bin/otrs.SetPermissions.pl
docker exec -u otrs otrs /opt/otrs/bin/otrs.Console.pl Maint::Cache::Delete
docker exec -u otrs otrs /opt/otrs/bin/otrs.Console.pl Maint::Loader::CacheCleanup
docker restart otrs
```

Ajustar nome do container (`otrs`) e caminho (`/opt/otrs`) conforme a instância.

## Por que funciona

`rm -rf var/tmp/*` remove o cache de template/loader antigo; `SetPermissions.pl` garante que os
diretórios recriados tenham dono/permissão corretos para o usuário de aplicação; `Maint::Cache::
Delete` e `Maint::Loader::CacheCleanup` invalidam o cache em nível de aplicação (não só o de
arquivo); o restart força a reconstrução completa dos assets minificados no novo ambiente.

## Escopo — o que este procedimento não cobre

Isso resolve cache de **template/loader/assets**. Não cobre cache de **configuração** (SysConfig)
nem valores de configuração LDAP/rede herdados do ambiente antigo — se depois da limpeza a
aplicação ainda tentar conectar a hosts/IPs do ambiente de origem, o problema está em outro nível
de cache (ex: SysConfig em banco/Redis) ou em arquivo de config gerado não coberto por este
comando. Ver `eliminar-ldap-stale-pos-restore.md` para essa camada.
