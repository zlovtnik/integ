# ==============================================================================
# Elixir CLM Integration - Makefile
# ==============================================================================
# Functional-first Elixir service for Contract Lifecycle Management
# Connects to Oracle ADB via wallet, uses Keycloak for auth
# ==============================================================================

.PHONY: all help deps compile build test test.unit test.integration test.watch \
        format lint dialyzer check dev run iex release release.docker \
        db.setup db.test.setup db.migrate clean docs oracle.check keycloak.check \
        docker.build docker.run docker.push docker.compose.up docker.compose.down

# ------------------------------------------------------------------------------
# Configuration
# ------------------------------------------------------------------------------

APP_NAME := gprint_ex
APP_VERSION := $(shell grep 'version:' mix.exs | head -1 | sed 's/.*version: "\(.*\)",/\1/')
MIX_ENV ?= dev
PORT ?= 4000

# Oracle Instant Client paths (platform-specific)
UNAME_S := $(shell uname -s)
ifeq ($(UNAME_S),Darwin)
    # macOS
    ORACLE_LIB := $(CURDIR)/../lib
    export DYLD_LIBRARY_PATH := $(ORACLE_LIB):$(DYLD_LIBRARY_PATH)
else
    # Linux
    ORACLE_LIB := $(CURDIR)/../lib-linux
    export LD_LIBRARY_PATH := $(ORACLE_LIB):$(LD_LIBRARY_PATH)
endif

# Wallet path
export TNS_ADMIN ?= $(CURDIR)/priv/wallet

# Docker
DOCKER_REGISTRY ?= ghcr.io
DOCKER_IMAGE := $(DOCKER_REGISTRY)/zlovtnik/$(APP_NAME)
DOCKER_TAG ?= $(APP_VERSION)

# Colors for output
CYAN := \033[36m
GREEN := \033[32m
YELLOW := \033[33m
RED := \033[31m
RESET := \033[0m

# ==============================================================================
# Help
# ==============================================================================

all: help

help: ## Show this help message
	@echo ""
	@echo "$(CYAN)╔══════════════════════════════════════════════════════════════════╗$(RESET)"
	@echo "$(CYAN)║     $(GREEN)Elixir CLM Integration - Makefile$(CYAN)                           ║$(RESET)"
	@echo "$(CYAN)╚══════════════════════════════════════════════════════════════════╝$(RESET)"
	@echo ""
	@echo "$(YELLOW)Usage:$(RESET) make [target]"
	@echo ""
	@echo "$(GREEN)Development:$(RESET)"
	@grep -E '^[a-zA-Z_.-]+:.*?## .*$$' $(MAKEFILE_LIST) | \
		awk 'BEGIN {FS = ":.*?## "}; /^(deps|compile|build|dev|run|iex)/ {printf "  $(CYAN)%-20s$(RESET) %s\n", $$1, $$2}'
	@echo ""
	@echo "$(GREEN)Testing:$(RESET)"
	@grep -E '^[a-zA-Z_.-]+:.*?## .*$$' $(MAKEFILE_LIST) | \
		awk 'BEGIN {FS = ":.*?## "}; /^test/ {printf "  $(CYAN)%-20s$(RESET) %s\n", $$1, $$2}'
	@echo ""
	@echo "$(GREEN)Quality:$(RESET)"
	@grep -E '^[a-zA-Z_.-]+:.*?## .*$$' $(MAKEFILE_LIST) | \
		awk 'BEGIN {FS = ":.*?## "}; /^(format|lint|dialyzer|check)/ {printf "  $(CYAN)%-20s$(RESET) %s\n", $$1, $$2}'
	@echo ""
	@echo "$(GREEN)Database:$(RESET)"
	@grep -E '^[a-zA-Z_.-]+:.*?## .*$$' $(MAKEFILE_LIST) | \
		awk 'BEGIN {FS = ":.*?## "}; /^db\./ {printf "  $(CYAN)%-20s$(RESET) %s\n", $$1, $$2}'
	@echo ""
	@echo "$(GREEN)Infrastructure:$(RESET)"
	@grep -E '^[a-zA-Z_.-]+:.*?## .*$$' $(MAKEFILE_LIST) | \
		awk 'BEGIN {FS = ":.*?## "}; /^(oracle|keycloak)/ {printf "  $(CYAN)%-20s$(RESET) %s\n", $$1, $$2}'
	@echo ""
	@echo "$(GREEN)Release & Docker:$(RESET)"
	@grep -E '^[a-zA-Z_.-]+:.*?## .*$$' $(MAKEFILE_LIST) | \
		awk 'BEGIN {FS = ":.*?## "}; /^(release|docker)/ {printf "  $(CYAN)%-20s$(RESET) %s\n", $$1, $$2}'
	@echo ""
	@echo "$(GREEN)Other:$(RESET)"
	@grep -E '^[a-zA-Z_.-]+:.*?## .*$$' $(MAKEFILE_LIST) | \
		awk 'BEGIN {FS = ":.*?## "}; /^(clean|docs)/ {printf "  $(CYAN)%-20s$(RESET) %s\n", $$1, $$2}'
	@echo ""

# ==============================================================================
# Development
# ==============================================================================

deps: ## Install all dependencies
	@echo "$(CYAN)► Installing dependencies...$(RESET)"
	mix deps.get
	@echo "$(GREEN)✓ Dependencies installed$(RESET)"

deps.update: ## Update all dependencies
	@echo "$(CYAN)► Updating dependencies...$(RESET)"
	mix deps.update --all
	@echo "$(GREEN)✓ Dependencies updated$(RESET)"

deps.tree: ## Show dependency tree
	mix deps.tree

compile: deps ## Compile the project
	@echo "$(CYAN)► Compiling...$(RESET)"
	mix compile --warnings-as-errors
	@echo "$(GREEN)✓ Compiled$(RESET)"

build: compile ## Alias for compile

dev: ## Run development server with hot reload
	@echo "$(CYAN)► Starting development server on port $(PORT)...$(RESET)"
	@echo "$(YELLOW)  TNS_ADMIN=$(TNS_ADMIN)$(RESET)"
	MIX_ENV=dev mix phx.server

run: ## Run the application (no hot reload)
	@echo "$(CYAN)► Starting application...$(RESET)"
	MIX_ENV=dev mix run --no-halt

iex: ## Start interactive Elixir shell with app loaded
	@echo "$(CYAN)► Starting IEx with app...$(RESET)"
	iex -S mix

iex.remote: ## Connect to running node via remote shell
	@echo "$(CYAN)► Connecting to remote node...$(RESET)"
	iex --sname console --remsh $(APP_NAME)@$$(hostname -s)

# ==============================================================================
# Testing
# ==============================================================================

test: ## Run all tests
	@echo "$(CYAN)► Running all tests...$(RESET)"
	MIX_ENV=test mix test
	@echo "$(GREEN)✓ Tests passed$(RESET)"

test.unit: ## Run unit tests only (domain layer)
	@echo "$(CYAN)► Running unit tests...$(RESET)"
	MIX_ENV=test mix test test/domain --trace
	@echo "$(GREEN)✓ Unit tests passed$(RESET)"

test.integration: ## Run integration tests (requires DB)
	@echo "$(CYAN)► Running integration tests...$(RESET)"
	MIX_ENV=test mix test test/boundaries test/infrastructure --trace
	@echo "$(GREEN)✓ Integration tests passed$(RESET)"

test.web: ## Run HTTP/controller tests
	@echo "$(CYAN)► Running web tests...$(RESET)"
	MIX_ENV=test mix test test/gprint_ex_web --trace
	@echo "$(GREEN)✓ Web tests passed$(RESET)"

test.watch: ## Run tests in watch mode
	@echo "$(CYAN)► Starting test watcher...$(RESET)"
	MIX_ENV=test mix test.watch

test.cover: ## Run tests with coverage report
	@echo "$(CYAN)► Running tests with coverage...$(RESET)"
	MIX_ENV=test mix coveralls.html
	@echo "$(GREEN)✓ Coverage report generated in cover/excoveralls.html$(RESET)"
	@open cover/excoveralls.html 2>/dev/null || true

test.failed: ## Re-run only failed tests
	@echo "$(CYAN)► Re-running failed tests...$(RESET)"
	MIX_ENV=test mix test --failed

# ==============================================================================
# Code Quality
# ==============================================================================

format: ## Format code
	@echo "$(CYAN)► Formatting code...$(RESET)"
	mix format
	@echo "$(GREEN)✓ Code formatted$(RESET)"

format.check: ## Check if code is formatted
	@echo "$(CYAN)► Checking format...$(RESET)"
	mix format --check-formatted
	@echo "$(GREEN)✓ Code is properly formatted$(RESET)"

lint: ## Run credo linter
	@echo "$(CYAN)► Running Credo...$(RESET)"
	mix credo --strict
	@echo "$(GREEN)✓ Credo passed$(RESET)"

lint.explain: ## Run credo with explanations
	mix credo --strict suggest --format=oneline

dialyzer: ## Run Dialyzer type checker
	@echo "$(CYAN)► Running Dialyzer (this may take a while on first run)...$(RESET)"
	mix dialyzer
	@echo "$(GREEN)✓ Dialyzer passed$(RESET)"

dialyzer.plt: ## Build PLT for Dialyzer
	@echo "$(CYAN)► Building Dialyzer PLT...$(RESET)"
	mix dialyzer --plt

check: format.check lint test ## Run all checks (format, lint, test)
	@echo "$(GREEN)✓ All checks passed$(RESET)"

check.full: format.check lint dialyzer test ## Run all checks including Dialyzer
	@echo "$(GREEN)✓ All checks passed$(RESET)"

# ==============================================================================
# Database
# ==============================================================================

db.setup: oracle.check ## Setup database (run migrations)
	@echo "$(CYAN)► Setting up database...$(RESET)"
	mix gprint.db.setup
	@echo "$(GREEN)✓ Database setup complete$(RESET)"

db.migrate: oracle.check ## Run pending migrations
	@echo "$(CYAN)► Running migrations...$(RESET)"
	mix gprint.db.migrate
	@echo "$(GREEN)✓ Migrations complete$(RESET)"

db.rollback: oracle.check ## Rollback last migration
	@echo "$(CYAN)► Rolling back last migration...$(RESET)"
	mix gprint.db.rollback
	@echo "$(GREEN)✓ Rollback complete$(RESET)"

db.reset: oracle.check ## Reset database (drop + setup)
	@echo "$(YELLOW)⚠ This will destroy all data!$(RESET)"
	@read -p "Are you sure? [y/N] " confirm && [ "$$confirm" = "y" ]
	mix gprint.db.reset
	@echo "$(GREEN)✓ Database reset complete$(RESET)"

db.test.setup: ## Setup test database
	@echo "$(CYAN)► Setting up test database...$(RESET)"
	MIX_ENV=test mix gprint.db.setup
	@echo "$(GREEN)✓ Test database ready$(RESET)"

db.console: oracle.check ## Open SQL console (sqlplus)
	@echo "$(CYAN)► Opening SQL console...$(RESET)"
	@if [ -z "$$ORACLE_USER" ]; then echo "$(RED)Error: ORACLE_USER not set$(RESET)"; exit 1; fi
	@if [ -z "$$ORACLE_TNS_ALIAS" ]; then echo "$(RED)Error: ORACLE_TNS_ALIAS not set$(RESET)"; exit 1; fi
	sqlplus $$ORACLE_USER@$$ORACLE_TNS_ALIAS

# ==============================================================================
# Infrastructure Checks
# ==============================================================================

oracle.check: ## Verify Oracle connectivity
	@echo "$(CYAN)► Checking Oracle connection...$(RESET)"
	@if [ ! -f "$(TNS_ADMIN)/tnsnames.ora" ]; then \
		echo "$(RED)✗ tnsnames.ora not found in $(TNS_ADMIN)$(RESET)"; \
		echo "$(YELLOW)  Copy tnsnames.ora.template and configure it$(RESET)"; \
		exit 1; \
	fi
	@if [ ! -f "$(TNS_ADMIN)/sqlnet.ora" ]; then \
		echo "$(RED)✗ sqlnet.ora not found in $(TNS_ADMIN)$(RESET)"; \
		echo "$(YELLOW)  Copy sqlnet.ora.template and configure it$(RESET)"; \
		exit 1; \
	fi
	@if [ ! -f "$(TNS_ADMIN)/cwallet.sso" ]; then \
		echo "$(RED)✗ cwallet.sso not found in $(TNS_ADMIN)$(RESET)"; \
		echo "$(YELLOW)  Download wallet from Oracle Cloud Console$(RESET)"; \
		exit 1; \
	fi
	@echo "$(GREEN)✓ Oracle wallet configured$(RESET)"
	@echo "$(CYAN)► Testing database connection...$(RESET)"
	mix gprint.db.ping || (echo "$(RED)✗ Connection failed$(RESET)" && exit 1)
	@echo "$(GREEN)✓ Oracle connection successful$(RESET)"

keycloak.check: ## Verify Keycloak connectivity
	@echo "$(CYAN)► Checking Keycloak connection...$(RESET)"
	@if [ -z "$$KEYCLOAK_BASE_URL" ]; then \
		echo "$(RED)✗ KEYCLOAK_BASE_URL not set$(RESET)"; \
		exit 1; \
	fi
	@curl -sf "$$KEYCLOAK_BASE_URL/realms/$$KEYCLOAK_REALM/.well-known/openid-configuration" > /dev/null && \
		echo "$(GREEN)✓ Keycloak reachable at $$KEYCLOAK_BASE_URL$(RESET)" || \
		(echo "$(RED)✗ Cannot reach Keycloak$(RESET)" && exit 1)

env.check: ## Verify all required environment variables
	@echo "$(CYAN)► Checking environment variables...$(RESET)"
	@missing=0; \
	for var in ORACLE_WALLET_PATH ORACLE_TNS_ALIAS ORACLE_USER ORACLE_PASSWORD JWT_SECRET; do \
		if [ -z "$$(eval echo \$$$$var)" ]; then \
			echo "$(RED)✗ $$var is not set$(RESET)"; \
			missing=1; \
		else \
			echo "$(GREEN)✓ $$var is set$(RESET)"; \
		fi; \
	done; \
	if [ $$missing -eq 1 ]; then exit 1; fi
	@echo "$(GREEN)✓ All required variables set$(RESET)"

# ==============================================================================
# Release & Docker
# ==============================================================================

release: ## Build production release
	@echo "$(CYAN)► Building release...$(RESET)"
	MIX_ENV=prod mix release --overwrite
	@echo "$(GREEN)✓ Release built: _build/prod/rel/$(APP_NAME)$(RESET)"

release.clean: ## Clean release artifacts
	@echo "$(CYAN)► Cleaning release...$(RESET)"
	rm -rf _build/prod/rel
	@echo "$(GREEN)✓ Release cleaned$(RESET)"

docker.build: ## Build Docker image
	@echo "$(CYAN)► Building Docker image $(DOCKER_IMAGE):$(DOCKER_TAG)...$(RESET)"
	docker build -t $(DOCKER_IMAGE):$(DOCKER_TAG) \
		--build-arg MIX_ENV=prod \
		--build-arg APP_VERSION=$(APP_VERSION) \
		.
	docker tag $(DOCKER_IMAGE):$(DOCKER_TAG) $(DOCKER_IMAGE):latest
	@echo "$(GREEN)✓ Docker image built$(RESET)"

docker.run: ## Run Docker container locally
	@echo "$(CYAN)► Running Docker container...$(RESET)"
	docker run --rm -it \
		-p $(PORT):$(PORT) \
		--env-file .env \
		-v $(CURDIR)/priv/wallet:/app/priv/wallet:ro \
		$(DOCKER_IMAGE):$(DOCKER_TAG)

docker.push: ## Push Docker image to registry
	@echo "$(CYAN)► Pushing to $(DOCKER_REGISTRY)...$(RESET)"
	docker push $(DOCKER_IMAGE):$(DOCKER_TAG)
	docker push $(DOCKER_IMAGE):latest
	@echo "$(GREEN)✓ Image pushed$(RESET)"

docker.compose.up: ## Start all services with docker-compose
	@echo "$(CYAN)► Starting services...$(RESET)"
	docker-compose up -d
	@echo "$(GREEN)✓ Services started$(RESET)"
	@docker-compose ps

docker.compose.down: ## Stop all services
	@echo "$(CYAN)► Stopping services...$(RESET)"
	docker-compose down
	@echo "$(GREEN)✓ Services stopped$(RESET)"

docker.compose.logs: ## Tail service logs
	docker-compose logs -f

# ==============================================================================
# Documentation
# ==============================================================================

docs: ## Generate documentation
	@echo "$(CYAN)► Generating documentation...$(RESET)"
	mix docs
	@echo "$(GREEN)✓ Documentation generated in doc/$(RESET)"
	@open doc/index.html 2>/dev/null || true

docs.api: ## Generate API documentation (OpenAPI)
	@echo "$(CYAN)► Generating OpenAPI spec...$(RESET)"
	mix openapi.spec.json --spec GprintExWeb.ApiSpec
	@echo "$(GREEN)✓ OpenAPI spec generated$(RESET)"

# ==============================================================================
# Cleanup
# ==============================================================================

clean: ## Clean build artifacts
	@echo "$(CYAN)► Cleaning...$(RESET)"
	mix clean
	rm -rf _build deps doc cover
	@echo "$(GREEN)✓ Clean$(RESET)"

clean.deps: ## Remove dependencies
	@echo "$(CYAN)► Removing dependencies...$(RESET)"
	rm -rf deps _build
	@echo "$(GREEN)✓ Dependencies removed$(RESET)"

clean.all: clean.deps ## Remove everything (full reset)
	@echo "$(CYAN)► Full cleanup...$(RESET)"
	rm -rf .elixir_ls .dialyzer
	@echo "$(GREEN)✓ Full cleanup complete$(RESET)"

# ==============================================================================
# Utilities
# ==============================================================================

routes: ## Show all routes
	mix phx.routes

outdated: ## Show outdated dependencies
	mix hex.outdated

audit: ## Run security audit
	@echo "$(CYAN)► Running security audit...$(RESET)"
	mix deps.audit
	mix sobelow --config
	@echo "$(GREEN)✓ Security audit complete$(RESET)"

.DEFAULT_GOAL := help
