# domain/

Inventário dos hosts gerenciados — dado de ambiente, não código. Cada host real vive em seu
próprio diretório-folha:

```
domain/<domínio>/<região>/<zona>/<pod>/<cluster>/<hostname>/
├── host.yaml   # endereço, porta, usuário, protocolo, groups, tags, identity_file
└── role.json   # opcional: sudoers específico deste host (complementa ia/policy/managed-identity.json)
```

Os níveis intermediários entre `domain/` e o diretório do host são livres — use quantos fizerem
sentido para a sua topologia (ex.: `domain/on-prem/compose/` com só 2 níveis é válido). O nome do
diretório-folha é o nome pelo qual o host é referenciado em toda ferramenta do subot (`ssh_exec`,
`identity sync`, etc.) — `Inventory.reload()` (`subot_core/inventory.py`) faz uma busca recursiva
por `host.yaml` e usa o nome do diretório-pai como chave.

`host.yaml` segue o mesmo schema de antes (quando vivia em `config/hosts.yaml`):

```yaml
address: 10.32.51.120
port: 22
user: subot
protocol: ssh
groups: [container-hosts]
tags: [protected]        # 'protected'/'prod' endurecem a política (ver subot_core/policy.py)
identity_file: null       # chave por-host opcional, relativa a bastiao/secrets/ssh/
```

`role.json`, se existir, tem o mesmo formato de `ia/policy/managed-identity.json` (uma lista
`sudoers`) — é mesclado com o manifesto padrão por `subot identity sync --host <nome>`.

**`domain/**/host.yaml` e `domain/**/role.json` nunca são versionados** (veja `.gitignore`) — são
dado real de ambiente, preservado só via `bastiao/scripts/backup.sh`. Este README é o único
arquivo rastreado dentro de `domain/`.

Para adicionar um host novo, use a skill `onboard-host` (ou a ferramenta MCP
`inventory_connector.add_host`, que sempre exige confirmação) em vez de criar `host.yaml` à mão.
