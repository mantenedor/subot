#!/usr/bin/env bash
# Baixa os modelos locais default (usados pelos agentes canônicos em ./agents/*.md) no Ollama,
# que roda dentro do container 'agent', para que os agentes funcionem 100% offline logo após
# 'docker compose up'.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

MODELS=("qwen2.5:14b" "qwen2.5:7b")

for model in "${MODELS[@]}"; do
    echo "==> baixando ${model}"
    docker compose exec -T agent ollama pull "${model}"
done

echo "==> concluído. Liste os modelos instalados com: docker compose exec agent ollama list"
