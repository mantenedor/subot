# Container único do subot: Claude Code (ponto de partida / uso interativo) + subot_orchestrator
# (motor multi-IA próprio, local-first) + Ollama (inferência local) + API REST + servidores MCP.
# Consolidado num container só de propósito — ver docker-compose.yml e README ("por que 4
# containers, não 8") para o raciocínio por trás dessa escolha.
FROM ollama/ollama:latest AS ollama-bin

FROM python:3.12-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
        curl ca-certificates gnupg openssh-client dropbear-bin sudo git less procps \
        iputils-ping dnsutils tmux \
    && curl -fsSL https://deb.nodesource.com/setup_20.x | bash - \
    && apt-get install -y --no-install-recommends nodejs \
    && npm install -g @anthropic-ai/claude-code \
    && mkdir -p -m 755 /etc/apt/keyrings \
    && curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
        -o /etc/apt/keyrings/githubcli-archive-keyring.gpg \
    && chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
        > /etc/apt/sources.list.d/github-cli.list \
    && apt-get update && apt-get install -y --no-install-recommends gh \
    && rm -rf /var/lib/apt/lists/*

# binário do Ollama copiado da imagem oficial (reprodutível, sem depender de ollama.com no build)
COPY --from=ollama-bin /bin/ollama /usr/local/bin/ollama

# sudo sem senha só DENTRO deste container — liberdade pra instalar pacotes/configurar/testar via
# o console SSH (Guacamole) ou 'docker compose exec'. Não dá acesso ao host nem aos outros
# containers (sem socket do Docker, sem privilégio extra no nível do Docker/kernel).
RUN useradd --create-home --uid 1000 --shell /bin/bash subot \
    && echo "subot ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/subot \
    && chmod 440 /etc/sudoers.d/subot

# Shell de login do 'subot' anexa/cria uma sessão tmux persistente ('-A') em vez de largar direto
# num bash solto. Sem isso, uma queda do console SSH (Guacamole/dropbear) mata o bash e tudo que
# roda nele (Claude Code incluso) junto com a sessão — ao reconectar, você caía num processo novo,
# sem contexto algum. Com tmux, reconectar reanexa ao mesmo processo, com o Claude ainda vivo
# dentro. 'export SHELL=/bin/bash' evita que os panes internos do tmux tentem reexecutar este
# mesmo wrapper (o que reentraria em outro tmux dentro do tmux, em loop).
RUN printf '#!/bin/sh\nexport SHELL=/bin/bash\nexec tmux new-session -A -s work\n' \
        > /usr/local/bin/subot-console-shell \
    && chmod +x /usr/local/bin/subot-console-shell \
    && echo /usr/local/bin/subot-console-shell >> /etc/shells \
    && usermod --shell /usr/local/bin/subot-console-shell subot

WORKDIR /opt/subot

COPY containers/agent/requirements.txt /tmp/requirements.txt
RUN pip install --no-cache-dir -r /tmp/requirements.txt

# packages/ é montado em runtime (bind mount) para ficar editável a partir do host; os pacotes
# subot_core e subot_orchestrator ficam disponíveis via PYTHONPATH, sem precisar reinstalar.
ENV PYTHONPATH=/opt/subot/packages/subot_core:/opt/subot/packages/subot_orchestrator
ENV OLLAMA_MODELS=/home/subot/.ollama
ENV OLLAMA_HOST=127.0.0.1:11434

RUN printf '#!/bin/sh\nexec python3 -m subot_orchestrator "$@"\n' > /usr/local/bin/subot \
    && chmod +x /usr/local/bin/subot

COPY containers/agent/app /opt/subot/app
COPY containers/agent/entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

USER subot
ENV HOME=/home/subot

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD ["sleep", "infinity"]
