.PHONY: setup pull-models up down logs ps backup restore rotate-keys sync-agents healthcheck

setup:
	bash scripts/setup.sh

pull-models:
	bash scripts/pull-models.sh

up:
	docker compose up -d

down:
	docker compose down

logs:
	docker compose logs -f

ps:
	docker compose ps

backup:
	bash scripts/backup.sh

restore:
	bash scripts/restore.sh $(ARCHIVE)

rotate-keys:
	bash scripts/rotate-ssh-keys.sh

sync-agents:
	python3 scripts/sync-claude-agents.py

healthcheck:
	bash scripts/healthcheck.sh
