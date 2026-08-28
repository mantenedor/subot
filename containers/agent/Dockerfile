# Container único do subot: Claude Code (ponto de partida / uso interativo) + subot_orchestrator
# (motor multi-IA próprio, local-first) + Ollama (inferência local) + API REST + servidores MCP.
# Consolidado num container só de propósito — ver docker-compose.yml e README ("por que 5
# containers, não 8") para o raciocínio por trás dessa escolha.
FROM ollama/ollama:latest AS ollama-bin

FROM python:3.12-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
        curl ca-certificates gnupg openssh-client dropbear-bin git less procps \
    && curl -fsSL https://deb.nodesource.com/setup_20.x | bash - \
    && apt-get install -y --no-install-recommends nodejs \
    && npm install -g @anthropic-ai/claude-code \
    && rm -rf /var/lib/apt/lists/*

# binário do Ollama copiado da imagem oficial (reprodutível, sem depender de ollama.com no build)
COPY --from=ollama-bin /bin/ollama /usr/local/bin/ollama

RUN useradd --create-home --uid 1000 --shell /bin/bash subot

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
