# subot (Super Bot)

Bastião/jump-server de infraestrutura orquestrado por IA, empacotado como uma stack Docker Compose
com rede própria e todos os volumes persistidos em diretórios do host (`./data`), fáceis de fazer
backup e com configuração editável diretamente do host (`./config`, `./agents`, `./.claude`,
`./mcp-servers`).

## Repositório vs. dados de ambiente

Este repositório carrega **só a ferramenta** — código, compose, agentes, skills, políticas
default — e nunca nenhum dado de uma instância específica. Tudo que identifica *um* ambiente real
fica fora do git (veja `.gitignore`) e é preservado só via `scripts/backup.sh`:

| No repositório (git) | Só no ambiente (backup, nunca git) |
|---|---|
| `docker-compose.yml`, `containers/`, `packages/`, `mcp-servers/`, `agents/*.md`, `.claude/`, `scripts/`, `install.sh` | `.env` (senhas) |
| `config/hosts.yaml.example` (template) | `config/hosts.yaml` (inventário real de hosts) |
| `config/providers.yaml`, `config/policy/*.yaml` (defaults genéricos) | `secrets/` (chaves SSH) |
| | `data/` (bancos, gravações de sessão, log de auditoria, modelos do Ollama) |

Isso torna o disaster-recovery em duas partes independentes e óbvias: `git clone` (ou
`install.sh`) traz a ferramenta pronta do zero; `scripts/backup.sh`/`restore.sh` carrega os
insumos de uma instância específica por cima dela.

## Princípio central: multi-IA, local-first

O Claude Code é o **ponto de partida**, não uma dependência obrigatória. Todo agente do subot é
definido uma única vez em `agents/*.md`, com um front matter que declara **qual IA o executa**:

```yaml
---
name: infra-operator
provider: ollama          # ollama | lmstudio | vllm | anthropic | openai | openrouter
model: qwen2.5:32b
fallback: [anthropic:claude-sonnet-5]
tools: [ssh_connector, remote_desktop_connector, inventory_connector, audit_connector]
---
```

Esse mesmo arquivo é consumido de duas formas:

- **Pelo `subot_orchestrator`** (`packages/subot_orchestrator`) — motor próprio que resolve
  `provider`+`model` via [LiteLLM](https://github.com/BerriAI/litellm) e dá ao agente acesso às
  ferramentas MCP diretamente. Roda 100% local usando o serviço `ollama` do compose, sem depender
  do Claude Code. É o caminho recomendado para uso contínuo/automatizado, e permite **delegação
  paralela**: um agente coordenador pode disparar vários outros — cada um em um provedor/modelo
  diferente — simultaneamente (`subot delegate`).
- **Pelo Claude Code**, para uso interativo. `scripts/sync-claude-agents.py` projeta
  `agents/*.md` para `.claude/agents/*.md` no formato que o Claude Code entende (o Claude Code
  sempre roda no seu próprio modelo; os campos `provider`/`model`/`fallback` só importam para o
  orquestrador).

Trocar a IA por trás de um agente é editar um campo no front matter — não uma mudança de código.

## Arquitetura

**4 containers** — deliberadamente poucos. `guac-db`/`guacd`/`guacamole` são o preço de manter o
Guacamole (a camada de acesso via navegador); Ollama e a API REST rodam **dentro** do container
`agent`, como processos em background, em vez de containers próprios — ver a nota "por que 4, não
8" logo abaixo.

| Serviço | Papel |
|---|---|
| `guac-db` | Banco Postgres do Guacamole (usuários, conexões, histórico) |
| `guacd` | Daemon proxy do Guacamole (fala RDP/VNC/SSH de verdade) |
| `guacamole` | Gateway web HTML5 — GUI remota, com gravação de sessão nativa. **Publicada direto em `8080` (HTTP puro, sem TLS)** — único ponto de entrada público da stack hoje |
| `agent` (container `subot-agent-1`) | Claude Code + `subot_orchestrator` + servidores MCP + **Ollama** (processo em background) + **API REST** (processo em background) — o "cérebro" único da stack (sem porta publicada) |

Todos na rede dedicada `subot_net`. A API (dentro do `agent`) não é publicada em lugar nenhum —
só alcançável de dentro da rede `subot_net` (ex.: `docker compose exec agent curl
localhost:8081/health`) até que algum proxy volte a ficar na frente dela (ver Fora de escopo).

> **Aviso de segurança**: `8080` serve Guacamole sem HTTPS — login e tudo mais trafegam em texto
> claro nessa porta. É uma escolha deliberada pra manter a stack simples enquanto não há um proxy
> validado na frente; adequado para debug/rede confiável, **não** para expor a uma rede não
> confiável — nesse caso, feche a porta (remova `ports:` do `guacamole` em `docker-compose.yml`)
> e resolva o acesso por outro caminho (VPN, túnel SSH, ou reintroduzindo um proxy — ver Fora de
> escopo).

**Por que 4 containers, não 8**: a primeira versão deste projeto tinha `ollama`, `api` e um
proxy reverso (Apache+certbot, depois Caddy) como containers próprios. Revisão de escopo: Ollama e
a API REST viraram processos em background dentro do `agent` (menos isolamento de restart/memória
entre eles, custo aceito conscientemente — se um crashar, `docker compose restart agent` religa os
três juntos). O proxy reverso (testado com Apache e depois com Caddy) foi **removido por ora** —
nenhum dos dois se provou simples o suficiente de sustentar antes de resolver o básico (Guacamole
acessível), então a stack roda sem TLS/proxy único por enquanto, com Guacamole exposta direto. O
Postgres do Guacamole **foi mantido** — é o que permite a tool `remote_desktop_connector` criar
conexões RDP/VNC/SSH dinamicamente via API; a alternativa sem banco (`user-mapping.xml` estático)
cortaria mais 1 container mas tiraria essa capacidade.

**Nome de serviço vs. nome de container**: nos comandos (`docker compose exec/logs/ps <serviço>`)
use o nome curto da tabela (`agent`, `guacamole`). No `docker ps`, o Docker Compose mostra o nome
completo do container, `<projeto>-<serviço>-<réplica>` — como o projeto já se chama `subot`, os
containers aparecem como `subot-agent-1`, `subot-guacamole-1` etc. É o mesmo container, só
nomeado de forma diferente pelas duas ferramentas — `docker exec` (fora do compose) precisa do
nome completo (`subot-agent-1`), `docker compose exec` aceita o nome curto do serviço (`agent`).

## Controles de segurança

Toda ação sobre um host gerenciado passa por `packages/subot_core`:

1. **`policy.py`** classifica cada comando como `safe` / `sensitive` / `destructive` / `blocked`
   a partir de `config/policy/allowlist.yaml` e `destructive_patterns.yaml`. Comando desconhecido
   nunca é `safe` por padrão (fail-closed) — vira `sensitive`.
2. **`confirm.py`** implementa confirmação em duas etapas ("break-glass"): uma ação não-safe
   retorna um `confirm_token` de uso único em vez de executar; só roda de fato numa segunda
   chamada explícita com esse token — vale para MCP, CLI e REST igualmente.
3. **`audit.py`** grava todo evento (tentado ou executado) em `./data/audit/*.jsonl`,
   append-only.
4. **`ssh.py`** usa `paramiko.RejectPolicy` — nunca aceita uma host key desconhecida
   automaticamente (`known_hosts` estrito).
5. Hosts marcados `protected`/`prod` em `config/hosts.yaml` têm risco elevado mesmo para comandos
   normalmente `safe`, e transferência de arquivo (`ssh_upload`/`ssh_download`) sempre exige
   confirmação.
6. Containers próprios rodam como usuário não-root; o socket do Docker nunca é montado; chaves SSH
   são montadas somente-leitura.
7. **A chave privada SSH do bastião é protegida por passphrase** (AES, formato nativo do
   OpenSSH/paramiko) — o arquivo em `secrets/ssh/` nunca é texto plano utilizável sozinho, mesmo
   que alguém tenha acesso de leitura ao disco do host. A passphrase é gerada por
   `scripts/setup.sh`, mostrada uma única vez no terminal e **nunca é salva em nenhum arquivo**
   (nem em `.env`, nem no backup). Isso protege contra disco/backup roubado; não protege contra
   alguém com root no host que decide entrar no container em execução (`docker exec`) — nenhuma
   configuração de container consegue evitar isso, é limitação de qualquer coisa rodando no mesmo
   kernel do host.

   Precisa reexportar `SUBOT_SSH_KEY_PASSPHRASE` só quando o container é **recriado**
   (`docker compose down && up`, `--force-recreate`, instalação nova) — um reboot simples da VM
   com `docker restart`/`restart: unless-stopped` reaproveita a configuração já gravada no
   container e não exige nada.

   **Risco operacional que você precisa aceitar conscientemente**: como a passphrase nunca é
   persistida, ela também **não entra em `scripts/backup.sh`**. Se você não guardá-la em algum
   lugar durável (gerenciador de senhas, cofre da organização) no momento em que ela aparece,
   restaurar o backup numa VM nova devolve a chave cifrada **sem nenhuma forma de abri-la** — a
   única saída nesse caso é gerar uma chave nova e redistribuir a chave pública para todos os
   hosts gerenciados. `scripts/backup.sh` e `scripts/restore.sh` avisam isso a cada execução.

## Dimensionamento de VM (CPU-only, escala pequena)

Estimativa para o cenário atual do projeto: **sem GPU** (Ollama roda em CPU) e **escala pequena**
(1–3 sessões RDP/VNC simultâneas, uso ocasional/moderado de agentes). Os dois fatores que dominam
o dimensionamento são (1) os modelos locais carregados no Ollama e (2) a codificação de vídeo do
`guacd` por sessão RDP/VNC ativa.

| Recurso | Mínimo viável | Recomendado | Ao crescer (5–10 sessões / uso intenso) |
|---|---|---|---|
| vCPU | 8 | **16** | 24–32, ou considerar GPU |
| RAM | 24 GB | **32 GB** | 48–64 GB |
| Disco | 150 GB SSD | **250–300 GB SSD/NVMe** | 500 GB+ NVMe |
| Rede | 20 Mbps | **50 Mbps simétrico** | 100+ Mbps |
| Swap | 8 GB | **16 GB** | 16–32 GB |

Como cheguei nesses números:

- **Plano de controle** (`guac-db` + `guacd` + `guacamole` + overhead de SO/Docker, excluindo
  Ollama): ~2–3 vCPU em pico, ~3–4 GB RAM. Leve na maior parte do tempo — o `guacd` é quem mais
  varia, porque cada sessão RDP/VNC ativa com atividade gráfica normal consome algo entre 0,3–0,8
  vCPU só para codificar vídeo.
- **Ollama (CPU-only)** é o item que mais pesa: com os defaults já ajustados neste projeto para
  CPU (`qwen2.5:14b` no `infra-operator`, `qwen2.5:7b` no `stack-maintainer` — ver
  `config/providers.yaml` e `agents/*.md`), cada modelo carregado ocupa ~10–12 GB (14b) ou ~5–6 GB
  (7b) de RAM residente; em uma delegação (`subot delegate`) ambos podem ficar carregados ao mesmo
  tempo, ~16–18 GB. Para throughput razoável (poucos tokens/s a alguns tokens/s) recomenda-se pelo
  menos 8 núcleos físicos dedicados e boa banda de memória (DDR4-3200 dual-channel ou melhor).
  **`qwen2.5:32b` continua disponível para uso manual, mas não é mais baixado por padrão** — em
  CPU pura ele tende a rodar devagar demais para o loop de tool-calling dos agentes (múltiplas
  idas e voltas por tarefa); prefira o fallback remoto (`security-auditor` já usa Anthropic com
  fallback local) quando precisar de mais qualidade e não tiver GPU.
- **Disco**: SO + imagens Docker (~15 GB) + modelos do Ollama (14b + 7b + folga para trocar de
  modelo, ~30–40 GB) + gravações de sessão do Guacamole (variável — reserve 30–50 GB com rotação
  periódica) + backups (mais 20–40 GB se mantiver várias gerações). NVMe é preferível a SATA SSD
  pelo tempo de carregamento dos modelos e pela responsividade do Postgres/log de auditoria.
- **Rede**: cada sessão RDP/VNC ativa em resolução/qualidade normais usa tipicamente 1–5 Mbps;
  para 3 sessões simultâneas com folga, 50 Mbps simétrico é confortável.
- **Swap**: rede de segurança contra OOM do Ollama em CPU (que é ávido por RAM), não uma
  estratégia de performance — inferência usando swap fica muito lenta, mas evita o processo
  morrer.

Se no futuro a VM ganhar uma GPU dedicada (passthrough), o quadro muda bastante: um modelo 32B
(ou maior) passa a ser viável para uso interativo, e o gargalo de CPU/RAM some quase todo — vale
reavaliar o dimensionamento nesse momento em vez de superdimensionar CPU/RAM hoje para compensar.

## Deploy em uma VM nova (um comando)

Rode a partir do diretório onde você quer manter o projeto (ex.: `/opt`) — o instalador cria
`./subot` **dentro do diretório de execução**, não em `$HOME`:

```bash
cd /opt   # ou onde preferir manter o projeto
curl -fsSL https://raw.githubusercontent.com/mantenedor/subot/main/install.sh | bash
```

Isso faz tudo sozinho, sem perguntar nada: checa/instala Docker, clona o repositório, gera a
chave SSH e sobe a stack **já usando a passphrase gerada nesta mesma execução** (você só precisa
guardá-la quando ela aparecer na tela — não precisa reexportar nada agora), baixa os modelos
locais do Ollama, projeta os agentes pro Claude Code e roda o checklist de saúde.

Rodar de novo (no mesmo diretório, ou apontando pra uma instalação existente) só pergunta algo
se detectar uma instalação/containers do subot já no ar — e nesse caso só oferece 3 escolhas:

```
[Enter] atualizar e continuar (padrão)
  r      reinstalar do zero (apaga tudo e clona de novo — pede confirmação)
  b      restaurar de um backup
```

Sem terminal interativo (ex.: rodando em CI), assume `[Enter]` (atualizar) automaticamente.

Se em algum momento o repositório voltar a ser privado, buscar o `install.sh` e o `git clone`
interno dele passam a exigir credencial — ver comentário no topo de `install.sh`. Ajustável via
`SUBOT_REPO_URL`, `SUBOT_REPO_REF` e `SUBOT_INSTALL_DIR`.

## Quickstart manual (sem o instalador)

```bash
bash scripts/setup.sh          # cria .env, config/hosts.yaml, chave SSH do bastião (com passphrase — anote!), schema do Guacamole
export SUBOT_SSH_KEY_PASSPHRASE='a-passphrase-que-o-setup.sh-mostrou'
docker compose up -d
bash scripts/register-console.sh   # cria a conexão "subot-console" no Guacamole
bash scripts/pull-models.sh    # baixa os modelos locais default no Ollama (qwen2.5:14b e 7b)
python3 scripts/sync-claude-agents.py   # projeta agents/*.md -> .claude/agents/*.md
```

- GUI (Guacamole): `http://IP-DA-VM:8080/guacamole/` (usuário/senha em `.env`,
  `GUACAMOLE_ADMIN_USER`/`GUACAMOLE_ADMIN_PASSWORD`, default `guacadmin`/`guacadmin` — troque
  depois do primeiro login; **habilite TOTP na conta admin do Guacamole** antes de considerar isso
  pronto para produção — é a autenticação real do sistema, e hoje é a única linha de defesa nessa
  porta, já que não há TLS nem proxy na frente).
- API REST: não publicada — só de dentro da rede `subot_net` ou via `docker compose exec agent`
  por enquanto (ver Fora de escopo).
- CLI/Claude Code: `docker compose exec -it agent bash`, depois `subot agent list` ou `claude`.

### Segurança na exposição de rede

Sem TLS/proxy na frente, `8080` serve Guacamole em texto claro — trate a rede entre o cliente e a
VM como não confiável por padrão:

- **Habilite TOTP no Guacamole** (extensão `guacamole-auth-totp`, já suportada pela imagem
  oficial via variáveis de ambiente — ver docs do Guacamole) assim que possível — é a autenticação
  real do sistema hoje.
- Restrinja `8080` por firewall a IPs/ranges/VPN conhecidos em vez de deixar aberta pra internet
  pública — sem TLS, isso é ainda mais importante do que seria com um proxy na frente.
- Instale `fail2ban` no **host** (fora do Docker) observando os logs do próprio Guacamole, para
  banir IPs com tentativas de login repetidas.
- Revise `./data/audit/*.jsonl` e as gravações de sessão em `./data/guac-recordings` com
  regularidade (a skill `incident-review` ajuda nisso).

## Console SSH da IA via Guacamole

`install.sh` (e `scripts/register-console.sh`, que ele chama) já deixam uma conexão
**"subot-console"** pronta no Guacamole — login no Guacamole (`http://IP:8080/guacamole/`) e
clicar nela cai direto num shell dentro do container `agent` (de onde dá pra rodar `claude`,
`subot agent list`, etc.), sem `docker exec` e sem tocar a rede/sshd da VM. Um `dropbear` roda em
background dentro do `agent`, só na rede docker interna, autenticado por uma chave dedicada
(`secrets/ssh/guac_console_ed25519`, gerada por `scripts/setup.sh`).

## Adicionando um host gerenciado

Edite `config/hosts.yaml` diretamente (é bind mount, reflete sem rebuild) ou use a skill
`onboard-host` / a ferramenta MCP `inventory_connector.add_host` (sempre exige confirmação). Esse
arquivo é gerado por `scripts/setup.sh` a partir de `config/hosts.yaml.example` (o template
versionado no git) e nunca é commitado — é dado de ambiente, preservado só via
`scripts/backup.sh`. Veja `config/hosts.yaml.example` para o formato e o significado das tags
`protected`/`prod`.

## Adicionando ou trocando a IA de um agente

Edite (ou crie) um arquivo em `agents/*.md`. Campos obrigatórios: `name`, `description`,
`provider` (um id de `config/providers.yaml`), `model`. Opcionais: `tools`, `fallback`,
`temperature`. Depois de editar, rode `python3 scripts/sync-claude-agents.py` para atualizar a
projeção em `.claude/agents/`.

Para usar um motor local diferente do Ollama (LM Studio, vLLM), preencha `LMSTUDIO_BASE_URL` ou
`VLLM_BASE_URL` em `.env` e aponte `provider: lmstudio` / `provider: vllm` no agente — nenhum dos
dois exige chave de API. Para um provedor remoto (`anthropic`, `openai`, `openrouter`), preencha a
chave correspondente em `.env`.

## Delegação multi-agente

```bash
docker compose exec agent subot delegate \
    "stack-maintainer=faça um health check" \
    "security-auditor=revise o log de auditoria das últimas 24h"
```

Cada agente roda no provider/model do seu próprio `agents/*.md`, em paralelo.

## Estrutura de diretórios

```
subot/
├── docker-compose.yml
├── containers/agent/                  # Dockerfile/entrypoint do agent (Claude Code+Ollama+API)
├── packages/
│   ├── subot_core/                    # segurança: inventory, policy, confirm, audit, ssh, secrets, guac_client
│   └── subot_orchestrator/            # multi-IA: providers, agent_loader, mcp_client, runner, delegator, cli
├── mcp-servers/{ssh,remote_desktop,inventory,audit}_connector/
├── agents/                            # definições canônicas de agente (multi-IA)
├── .claude/{settings.json,agents,skills}/   # projeção Claude Code + skills
├── config/{hosts.yaml.example,providers.yaml,policy/}   # hosts.yaml (real) é gerado, nunca versionado
├── secrets/ssh/                       # NUNCA versionado — dado de ambiente
├── data/                              # NUNCA versionado — todos os volumes, como diretórios do host
├── install.sh                         # instalador de um comando (curl | bash) para VM nova
└── scripts/                           # setup, pull-models, sync, backup, restore, rotação de chaves,
                                        # healthcheck
```

## Fora de escopo (próximos passos)

- **Proxy reverso / TLS único ponto de entrada** — testado com Apache+certbot e depois com Caddy;
  nenhum dos dois ficou estável o suficiente antes de resolver o básico (Guacamole acessível), e
  foi removido do projeto por ora. Guacamole roda em HTTP puro na `8080` enquanto isso. Se
  reconsiderar, avalie testar bem localmente antes de assumir que "vai simplificar" — os dois
  causaram mais atrito do que o esperado nesta rodada.
- TOTP no Guacamole e `fail2ban` no host — recomendados na seção de segurança acima, mas não
  configurados automaticamente por nenhum script.
- Testes de integração ponta-a-ponta automatizados.
- SSO/LDAP no Guacamole.
- Segmentação em múltiplas redes Docker (hoje é uma rede única `subot_net`).
- Guacamole sem banco (`user-mapping.xml`) — cortaria o container `guac-db`, mas tiraria a
  criação dinâmica de conexão via `remote_desktop_connector` (decisão consciente de manter o
  banco — ver seção Arquitetura).
- UI web própria para gestão dos agentes (v1 usa CLI/API/Guacamole).
- Outros CLIs de agente de código (aider, opencode, etc.) além do Claude Code como driver
  interativo — a arquitetura já suporta isso via `subot_orchestrator`, mas nenhum foi integrado
  nesta primeira entrega.
- GPU passthrough para o Ollama — ver nota de dimensionamento acima.

## Licença

[PolyForm Noncommercial License 1.0.0](LICENSE) — uso livre para qualquer propósito
**não-comercial** (pessoal, pesquisa, estudo, organizações sem fins lucrativos, educacionais, de
saúde pública, ambientais ou governamentais). Uso comercial não é permitido sob esta licença. Este
não é um aconselhamento jurídico — para dúvidas sobre um uso específico, consulte um advogado.
