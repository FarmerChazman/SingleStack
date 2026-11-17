SHELL        := /usr/bin/env bash
.SHELLFLAGS  := -euo pipefail -c
.DEFAULT_GOAL := help

COMPOSE := docker compose --env-file .env
-include .env
EDGE_NETWORK ?= edge

.PHONY: help init network preflight up down restart ps logs doctor backup restore upgrade \
        psql chatwoot-console lint test email-routing-plan email-routing-apply email-routing-status

help: ## List targets
	@awk 'BEGIN{FS=":.*## "} /^[a-z-]+:.*## /{printf "  \033[36m%-22s\033[0m %s\n", $$1, $$2}' $(MAKEFILE_LIST)

# ── setup ──────────────────────────────────────────────────────────────────
init: ## Create .env with fresh secrets: make init DOMAIN=example.com
	@scripts/init-env.sh "$(DOMAIN)"

network: ## Create the edge network (make up does this too)
	@docker network inspect $(EDGE_NETWORK) >/dev/null 2>&1 \
	  && echo "network $(EDGE_NETWORK) exists" \
	  || docker network create $(EDGE_NETWORK)

preflight: ## Read-only checks: config, ports, network, resources, egress
	@scripts/preflight.sh

# ── cloudflare email routing (all domains) ───────────────────────────────
email-routing-plan: ## Show Email Routing changes for every domain in deploy/cloudflare/email-routing.conf
	@scripts/cf-email-routing.sh plan

email-routing-apply: ## Apply them (enable zones, subaddressing, rules, catch-alls)
	@scripts/cf-email-routing.sh apply

email-routing-status: ## Settings, SPF, rules and expected DNS per domain
	@scripts/cf-email-routing.sh status

# ── lifecycle ──────────────────────────────────────────────────────────────
up: ## Start / reconcile the stack and wait until healthy
	@scripts/up.sh

down: ## Stop and remove containers (volumes are kept)
	$(COMPOSE) down

restart: ## Restart app containers (not the databases)
	$(COMPOSE) restart chatwoot-web chatwoot-worker listmonk

ps: ## Container status
	$(COMPOSE) ps

logs: ## Follow logs: make logs [s=chatwoot-web]
	$(COMPOSE) logs -f --tail=200 $(s)

doctor: ## Health: containers, endpoints, ingress, public hostnames
	@scripts/doctor.sh

# ── data ───────────────────────────────────────────────────────────────────
backup: ## Dump databases + files + .env into BACKUP_DIR
	@scripts/backup.sh

restore: ## Restore a backup (destructive): make restore FROM=backups/<stamp>
	@scripts/restore.sh "$(FROM)"

upgrade: ## Backup, pull pinned images, migrate, wait healthy
	@scripts/backup.sh
	@scripts/up.sh --pull
	@scripts/doctor.sh

# ── debugging ──────────────────────────────────────────────────────────────
psql: ## psql shell: make psql [db=chatwoot]
	docker exec -it ss-postgres psql -U postgres $(or $(db),postgres)

chatwoot-console: ## Rails console in the Chatwoot web container
	docker exec -it ss-chatwoot bundle exec rails c

# ── quality ────────────────────────────────────────────────────────────────
lint: ## shellcheck + compose render + worker typecheck (same as CI)
	shellcheck -x scripts/*.sh scripts/lib/*.sh services/postgres/initdb/*.sh tests/*/*.sh
	@tmp=$$(mktemp -u); ENV_FILE=$$tmp scripts/init-env.sh ci.example.org >/dev/null; \
	  sed -i 's/^CHATWOOT_SMTP_USER=$$/CHATWOOT_SMTP_USER=ci/; s/^CHATWOOT_SMTP_KEY=$$/CHATWOOT_SMTP_KEY=ci/' $$tmp; \
	  docker compose --env-file $$tmp config -q && echo "compose: ok"; rm -f $$tmp
	cd workers/inbound-mail && npm run --silent typecheck

test: ## Worker unit tests + Email Routing script against a mock Cloudflare API
	cd workers/inbound-mail && npm test --silent
	tests/cf-email-routing/run.sh
