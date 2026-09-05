# subot

Bastião/jump-server de infraestrutura orquestrado por IA: um agente (Claude Code ou um motor
local via Ollama/LM Studio/vLLM) executa comandos em hosts remotos via SSH e abre sessões
gráficas RDP/VNC através do Guacamole — sempre com política de segurança, confirmação em duas
etapas e auditoria completa por baixo.

**Para que serve, na prática**: operação de servidores assistida por IA (deploy, diagnóstico,
manutenção) com trilha de auditoria; acesso remoto via navegador a máquinas Linux/Windows sem
expor RDP/VNC direto à rede; delegação de tarefas de infraestrutura para vários agentes
especializados rodando em paralelo, cada um na IA que fizer mais sentido para a tarefa.

## Como funciona

```
              Claude Code / IA local
                        │
                        ▼
              ┌───────────────────┐
              │       subot       │   política · confirmação em 2 etapas · auditoria
              └─────────┬─────────┘
                 ┌───────┴────────┐
                 ▼                ▼
        SSH (hosts geridos)   Guacamole (RDP/VNC)
```

Arquitetura completa, controles de segurança, dimensionamento de VM e roadmap:
[`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md).

## Deploy

Numa VM nova, um comando — rode a partir do diretório onde quer manter o projeto (ex. `/opt`):

```bash
cd /opt
curl -fsSL https://raw.githubusercontent.com/mantenedor/subot/main/install.sh | bash
```

Isso instala Docker, clona o repositório, gera a chave SSH do bastião (a passphrase aparece
**uma única vez** no terminal — guarde-a), sobe a stack, baixa os modelos locais do Ollama,
projeta os agentes para o Claude Code e roda o checklist de saúde. Rodar de novo no mesmo
diretório é seguro: detecta uma instalação existente e só pergunta entre atualizar, reinstalar
do zero ou restaurar de um backup.

Depois do deploy:

- **GUI (Guacamole)**: `http://IP-DA-VM:8080/guacamole/` — login/senha em `.env`
  (`GUACAMOLE_ADMIN_USER`/`GUACAMOLE_ADMIN_PASSWORD`, padrão `guacadmin`/`guacadmin` — troque no
  primeiro acesso).
- **CLI/Claude Code**: `docker compose exec -it agent bash`, depois `claude` ou
  `subot agent list`.

> ⚠️ **Sem TLS na frente**, `8080` serve Guacamole em texto claro — antes de expor a porta a uma
> rede não confiável, veja [Segurança na exposição de
> rede](docs/ARCHITECTURE.md#segurança-na-exposição-de-rede).

Passo a passo do quickstart manual (sem o instalador), console SSH da IA via Guacamole,
como adicionar um host gerenciado ou trocar a IA de um agente, instalação do gate de privilégio
no host gerenciado, e delegação multi-agente: tudo em
[`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md#guia-de-operação).

## Licença

[PolyForm Noncommercial License 1.0.0](LICENSE) — uso livre para qualquer propósito
**não-comercial** (pessoal, pesquisa, estudo, organizações sem fins lucrativos, educacionais, de
saúde pública, ambientais ou governamentais). Uso comercial não é permitido sob esta licença. Este
não é um aconselhamento jurídico — para dúvidas sobre um uso específico, consulte um advogado.
