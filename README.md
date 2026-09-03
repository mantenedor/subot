# subot (Super Bot)

Bastião/jump-server de infraestrutura orquestrado por IA: uma stack Docker Compose que dá a
agentes de IA (Claude Code ou motores locais via Ollama/LM Studio/vLLM) acesso controlado a hosts
gerenciados — via SSH e sessões remotas RDP/VNC através do Guacamole — com política de segurança,
confirmação em duas etapas e auditoria completa por baixo (`packages/subot_core`).

Para arquitetura, controles de segurança, dimensionamento de VM e roadmap, veja
[`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md).

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
  pronto para produção).
- API REST: não publicada — só de dentro da rede `subot_net` ou via `docker compose exec agent`.
- CLI/Claude Code: `docker compose exec -it agent bash`, depois `subot agent list` ou `claude`.

> ⚠️ **Sem TLS/proxy na frente**, `8080` serve Guacamole em texto claro — antes de expor a porta a
> uma rede não confiável, veja "Segurança na exposição de rede" em
> [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md#segurança-na-exposição-de-rede).

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

## Dois usuários por host gerenciado (`subot` / `subotsu`)

Padrão recomendado: cada host gerenciado deve ter **dois usuários Linux**, ambos autenticados só
pela chave pública do bastião (`secrets/ssh/bastion_id_ed25519.pub`) — `subot` (sem sudo, uso
diário) e `subotsu` (sudo `NOPASSWD` restrito, só para ações que já passaram pela confirmação em
duas etapas). Racional completo em
[`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md#dois-usuários-por-host-gerenciado-subot--subotsu--racional).

Criar os dois usuários em cada host gerenciado (rode como root/via usuário existente com sudo):

```bash
# em cada host gerenciado
useradd --create-home --shell /bin/bash subot
useradd --create-home --shell /bin/bash subotsu

install -d -m 700 /home/subot/.ssh /home/subotsu/.ssh
cp /caminho/para/bastion_id_ed25519.pub /home/subot/.ssh/authorized_keys
cp /caminho/para/bastion_id_ed25519.pub /home/subotsu/.ssh/authorized_keys
chmod 600 /home/subot/.ssh/authorized_keys /home/subotsu/.ssh/authorized_keys
chown -R subot:subot /home/subot/.ssh
chown -R subotsu:subotsu /home/subotsu/.ssh

# sudo do subotsu: prefira listar comandos específicos em vez de ALL — ajuste ao seu caso
echo 'subotsu ALL=(ALL) NOPASSWD: /usr/bin/systemctl, /usr/bin/apt-get, /usr/bin/docker' \
    > /etc/sudoers.d/subotsu
chmod 440 /etc/sudoers.d/subotsu
```

**Status atual:** `config/hosts.yaml` só tem um campo `user:` por host — não há seleção
automática de usuário por classificação de comando ainda. Convenção interina: registre o host
duas vezes em `config/hosts.yaml` (uma para `user: subot`, outra com sufixo claro, ex.
`meu-host-su`, tag `protected`, `user: subotsu`).

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

## Licença

[PolyForm Noncommercial License 1.0.0](LICENSE) — uso livre para qualquer propósito
**não-comercial** (pessoal, pesquisa, estudo, organizações sem fins lucrativos, educacionais, de
saúde pública, ambientais ou governamentais). Uso comercial não é permitido sob esta licença. Este
não é um aconselhamento jurídico — para dúvidas sobre um uso específico, consulte um advogado.
