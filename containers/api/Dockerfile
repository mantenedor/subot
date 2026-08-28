# API REST do subot: mesmas operações de segurança/infra dos agentes, agnóstica de qual IA está
# por trás de cada um — para uso por humanos/automação fora do Claude Code.
FROM python:3.12-slim

RUN apt-get update && apt-get install -y --no-install-recommends openssh-client \
    && rm -rf /var/lib/apt/lists/*

RUN useradd --create-home --uid 1000 --shell /bin/bash subot

WORKDIR /opt/subot

COPY containers/api/requirements.txt /tmp/requirements.txt
RUN pip install --no-cache-dir -r /tmp/requirements.txt

ENV PYTHONPATH=/opt/subot/packages/subot_core:/opt/subot/packages/subot_orchestrator

COPY containers/api/entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh
COPY containers/api/app /opt/subot/app

USER subot
ENV HOME=/home/subot

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8081"]
