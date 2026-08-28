# Container "cérebro" do subot: Claude Code (ponto de partida / uso interativo) + subot_orchestrator
# (motor multi-IA próprio, local-first) + servidores MCP.
FROM python:3.12-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
        curl ca-certificates gnupg openssh-client git less procps \
    && curl -fsSL https://deb.nodesource.com/setup_20.x | bash - \
    && apt-get install -y --no-install-recommends nodejs \
    && npm install -g @anthropic-ai/claude-code \
    && rm -rf /var/lib/apt/lists/*

RUN useradd --create-home --uid 1000 --shell /bin/bash subot

WORKDIR /opt/subot

COPY containers/agent/requirements.txt /tmp/requirements.txt
RUN pip install --no-cache-dir -r /tmp/requirements.txt

# packages/ é montado em runtime (bind mount) para ficar editável a partir do host; os pacotes
# subot_core e subot_orchestrator ficam disponíveis via PYTHONPATH, sem precisar reinstalar.
ENV PYTHONPATH=/opt/subot/packages/subot_core:/opt/subot/packages/subot_orchestrator

RUN printf '#!/bin/sh\nexec python3 -m subot_orchestrator "$@"\n' > /usr/local/bin/subot \
    && chmod +x /usr/local/bin/subot

COPY containers/agent/entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

USER subot
ENV HOME=/home/subot

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD ["sleep", "infinity"]
