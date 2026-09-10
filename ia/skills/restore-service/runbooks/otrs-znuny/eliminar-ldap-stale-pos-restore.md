# OTRS/Znuny: eliminar autenticação/sync LDAP stale (IP do ambiente antigo) após restaurar/migrar instância

## Objetivo

Eliminar tentativas de conexão a um LDAP do ambiente de origem (IP/host que não existe mais para a
instância restaurada), que causam timeout de conexão e lentidão perceptível no carregamento da
interface do OTRS/Znuny — sem depender de reabrir rota de rede para o ambiente antigo.

Pré-requisito: LDAP não está mais em uso no ambiente novo (decisão de negócio). Se LDAP ainda for
necessário, o ajuste é apontar as settings de host para o LDAP correto em vez de desativá-las — o
procedimento de localização é o mesmo.

## Sintoma

```
error    OTRS-CGI-0    Got no SessionID!!
error    OTRS-CGI-0    First bind failed! Interrupted system call
error    OTRS-CGI-0    Can't connect to <IP-do-ambiente-antigo>: Connection timed out
```

com traceback apontando para `Kernel::System::Auth::*LDAP*` (`Kernel::System::Auth::LDAP`,
`Kernel::System::Auth::Sync::LDAP`, `Kernel::System::CustomerAuth::LDAP`, `Kernel::System::
CustomerAuth::Sync::LDAP`, conforme o backend). O padrão não é constante — só afeta requests que
passam pelo caminho de autenticação/sync específico que ainda aponta pro LDAP antigo.

Este procedimento complementa `limpar-cache-loader-pos-restore.md`: aquele resolve cache de
template/loader/assets; este resolve cache/config de **autenticação**, que é uma camada diferente.

## Por que acontece

Uma migração via `rsync`/cópia de volume costuma trazer a árvore `/opt/otrs` (ou equivalente)
inteira do ambiente antigo — não só dados de aplicação, mas o próprio código/config da instância,
incluindo `Kernel/Config/Defaults.pm`. Esse arquivo pode conter valores hardcoded de LDAP herdados
do ambiente antigo por dois motivos possíveis:

1. Alguém editou o XML de SysConfig na origem de forma não padrão, fazendo esse valor virar
   "default" em vez de override.
2. As settings de LDAP foram configuradas do jeito tradicional do OTRS — **editando `Defaults.pm`/
   `Kernel/Config.pm` diretamente em Perl**, fora do sistema de SysConfig/XML — prática comum para
   blocos de config LDAP mais complexos (`UserSyncMap`, `GroupDN`, filtros). Isso é especialmente
   provável para `AuthSyncModule`/`Customer::AuthSyncModule`.

A consequência prática: existem **duas famílias de causa**, que exigem correções diferentes, e
corrigir uma não corrige a outra.

## Procedimento

### 1. Localizar TODAS as settings de módulo de auth ativas (não só uma)

Existem até 4 variantes independentes, cada uma podendo ter sufixo numérico (`N`) se houver
múltiplos backends configurados:

- `AuthModule` — auth de agente
- `AuthSyncModule` — sync de agente
- `Customer::AuthModule` — auth de customer
- `Customer::AuthSyncModule` — sync de customer

Checar as duas fontes possíveis — o que está **deployado** via SysConfig (`ZZZAAuto.pm`) e o
**default bruto** (`Defaults.pm`), já que uma setting pode existir só em um dos dois:

```bash
docker exec -u otrs otrs grep -n "AuthModule\|AuthSyncModule" /opt/otrs/Kernel/Config/Files/ZZZAAuto.pm /opt/otrs/Kernel/Config/Defaults.pm
```

Atenção: `Defaults.pm` pode declarar a chave **sem aspas** (`$Self->{AuthSyncModule} = ...`),
diferente do padrão com aspas usado em settings geradas via SysConfig (`$Self->{'Setting::Name'} =
...`). Um grep/regex que assuma aspas ao redor do nome da chave não encontra essa variante — use
um grep simples por substring, não uma regex ancorada em aspas.

Qualquer linha cujo valor seja uma classe `*::LDAP*`/`*::LDAP::Sync*` é candidata a estar causando
o timeout.

### 2. Se a setting está registrada no SysConfig (aparece na busca da UI Admin → System Configuration)

Corrigir por lá — é o caso típico de `AuthModule`/`Customer::AuthModule`.

```bash
docker exec -u otrs otrs /opt/otrs/bin/otrs.Console.pl Admin::Config::Update --setting-name "<Nome::Da::Setting>" --value "Kernel::System::Auth::DB"          # agente
docker exec -u otrs otrs /opt/otrs/bin/otrs.Console.pl Admin::Config::Update --setting-name "Customer::AuthModule" --value "Kernel::System::CustomerAuth::DB"  # customer
```

**Armadilha confirmada**: `Admin::Config::Update` só grava o valor como "modificado" (draft) — não
deploya. `Maint::Config::Rebuild` regenera `ZZZAAuto.pm` a partir da última configuração
**deployada**, não do draft. O comando retorna "Done." mas nada muda em runtime até deployar de
verdade.

**Deploy confiável**: pela UI (Admin → System Configuration → editar a setting → botão **Deploy**,
não só salvar). Confirmar que não sobrou "implementação pendente" antes de seguir. Depois validar:

```bash
docker exec -u otrs otrs grep -n "<Nome::Da::Setting>" /opt/otrs/Kernel/Config/Files/ZZZAAuto.pm
```

### 3. Se a setting NÃO aparece na busca do SysConfig UI

Isso indica que ela nunca foi um setting XML-registrado — foi injetada como Perl puro direto em
`Defaults.pm` (ou `Kernel/Config.pm`), fora do sistema de SysConfig. É o caso típico de
`AuthSyncModule`/`Customer::AuthSyncModule` com blocos LDAP complexos (`UserSyncMap`, `GroupDN`,
etc.).

Não adianta tentar deployar via SysConfig — a única correção é editar o arquivo diretamente.
Comentar a linha (rodar como `root`, já que o arquivo normalmente não é gravável pelo usuário de
aplicação):

```bash
docker exec -u root otrs sed -i "/NomeDaSetting} = 'Kernel::System::Auth::Sync::LDAP'/s/^/#/" /opt/otrs/Kernel/Config/Defaults.pm
```

Ajustar o texto do match para a classe/setting exata encontrada no passo 1. Evitar usar `$Self` no
padrão do `sed` ao rodar num shell que faz expansão de variável (bash expande `$Self` como
variável, resultando em string vazia e quebrando o match) — usar como âncora o texto a partir de
`NomeDaSetting} = '...'`, sem o prefixo `$Self->{`.

Validar:

```bash
docker exec -u otrs otrs grep -n "NomeDaSetting} = " /opt/otrs/Kernel/Config/Defaults.pm
```

(deve aparecer comentado com `#` na frente).

Nota: ao contrário do que se poderia supor, `Maint::Config::Rebuild` **não** reescreve
`Defaults.pm` a partir do XML nesse tipo de instalação — a edição direta se manteve estável mesmo
após rodar o rebuild múltiplas vezes. Não foi necessário reverter a edição manual.

### 4. Limpar cache e reiniciar — sempre, depois de qualquer mudança dos passos 2 ou 3

```bash
docker exec -u otrs otrs /opt/otrs/bin/otrs.Console.pl Maint::Cache::Delete
docker restart otrs
```

### 5. Confirmar

- Repetir o grep do passo 1 e confirmar que nenhuma setting de módulo de auth/sync ativo aponta
  mais para `*LDAP*`.
- Acompanhar o log por um período de uso real e confirmar que o `Can't connect to <IP-antigo>`
  parou de aparecer.

## Lições

- **Corrigir uma variante (ex: `Customer::AuthModule`) não garante que as outras três estejam
  corretas** — cheque as quatro sempre, mesmo que o sintoma pareça ter sumido depois da primeira
  correção.
- **`Admin::Config::Update` (console) não deploya sozinho** — sempre confirmar deploy pela UI
  antes de assumir que uma mudança de SysConfig teve efeito.
- **Nem toda config de LDAP no OTRS/Znuny está no SysConfig** — se a busca da UI não encontra a
  setting, ela provavelmente é Perl puro em `Defaults.pm`/`Config.pm`, e a correção é edição
  direta do arquivo, não deploy.
- Antes de aceitar "resolvido" só pelo log parar de reclamar, valide também que a interface voltou
  à velocidade normal — o sintoma de negócio (lentidão) é o critério real de fechamento, não só a
  ausência da mensagem de erro.

## Referências

- `limpar-cache-loader-pos-restore.md` — cache de template/loader (camada diferente desta).
