.PHONY: setup pull-models up down logs ps backup restore rotate-keys sync-agents healthcheck

setup:
	bash bastiao/scripts/setup.sh

pull-models:
	bash bastiao/scripts/pull-models.sh

up:
	cd bastiao && docker compose up -d

down:
	cd bastiao && docker compose down

logs:
	cd bastiao && docker compose logs -f

ps:
	cd bastiao && docker compose ps

backup:
	bash bastiao/scripts/backup.sh

restore:
	bash bastiao/scripts/restore.sh $(ARCHIVE)

rotate-keys:
	bash bastiao/scripts/rotate-ssh-keys.sh

sync-agents:
	python3 bastiao/scripts/sync-claude-agents.py

healthcheck:
	bash bastiao/scripts/healthcheck.sh
