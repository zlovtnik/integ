# ==============================================================================
# Elixir CLM Integration - Makefile
# ==============================================================================
# Functional-first Elixir service for Contract Lifecycle Management
# Connects to Oracle ADB via wallet, uses Keycloak for auth
# ==============================================================================

.PHONY: all help deps compile build test test.unit test.integration test.watch \
        test.coverage format format.check lint dialyzer check dev run iex \
        release db.setup db.test.setup clean docs oracle.check keycloak.check \
        docker.build docker.run docker.push docker.compose.up docker.compose.down setup

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
		awk 'BEGIN {FS = ":.*?## "}; /^(clean|docs|setup)/ {printf "  $(CYAN)%-20s$(RESET) %s\n", $$1, $$2}'
	@echo ""

# ==============================================================================
# Development
# ==============================================================================

deps: ## Install all dependencies
	@echo "$(CYAN)► Installing dependencies...$(RESET)"
	mix deps.get
	@echo "$(GREEN)✓ Dependencies installed$(RESET)"

compile: deps ## Compile the project
	@echo "$(CYAN)► Compiling...$(RESET)"
	mix compile
	@echo "$(GREEN)✓ Compilation complete$(RESET)"

build: compile ## Build the application
	@echo "$(CYAN)► Building...$(RESET)"
	MIX_ENV=prod mix compile
	@echo "$(GREEN)✓ Build complete$(RESET)"

dev: deps ## Start development server with iex
	@echo "$(CYAN)► Starting development server...$(RESET)"
	iex -S mix phx.server

run: deps ## Start the server (no iex)
	@echo "$(CYAN)► Starting server...$(RESET)"
	mix phx.server

iex: deps ## Start iex session
	@echo "$(CYAN)► Starting iex...$(RESET)"
	iex -S mix

# ==============================================================================
# Testing
# ==============================================================================

test: ## Run all tests
	@echo "$(CYAN)► Running all tests...$(RESET)"
	MIX_ENV=test mix test
	@echo "$(GREEN)✓ Tests complete$(RESET)"

test.unit: ## Run unit tests (domain layer)
	@echo "$(CYAN)► Running unit tests...$(RESET)"
	MIX_ENV=test mix test test/domain test/result_test.exs --exclude integration
	@echo "$(GREEN)✓ Unit tests complete$(RESET)"

test.integration: ## Run integration tests
	@echo "$(CYAN)► Running integration tests...$(RESET)"
	MIX_ENV=test mix test test/boundaries test/infrastructure --include integration
	@echo "$(GREEN)✓ Integration tests complete$(RESET)"

test.watch: ## Run tests in watch mode
	@echo "$(CYAN)► Starting test watcher...$(RESET)"
	MIX_ENV=test mix test.watch

test.coverage: ## Run tests with coverage
	@echo "$(CYAN)► Running tests with coverage...$(RESET)"
	MIX_ENV=test mix coveralls
	@echo "$(GREEN)✓ Coverage report generated$(RESET)"

# ==============================================================================
# Quality
# ==============================================================================

format: ## Format code
	@echo "$(CYAN)► Formatting code...$(RESET)"
	mix format
	@echo "$(GREEN)✓ Code formatted$(RESET)"

format.check: ## Check code formatting
	@echo "$(CYAN)► Checking format...$(RESET)"
	mix format --check-formatted
	@echo "$(GREEN)✓ Format check passed$(RESET)"

lint: ## Run Credo linter
	@echo "$(CYAN)► Running Credo...$(RESET)"
	mix credo --strict
	@echo "$(GREEN)✓ Credo passed$(RESET)"

dialyzer: ## Run Dialyzer static analysis
	@echo "$(CYAN)► Running Dialyzer...$(RESET)"
	mix dialyzer
	@echo "$(GREEN)✓ Dialyzer passed$(RESET)"

check: format.check lint dialyzer ## Run all quality checks
	@echo "$(GREEN)✓ All quality checks passed$(RESET)"

# ==============================================================================
# Database
# ==============================================================================

db.setup: ## Set up database (run migrations)
	@echo "$(CYAN)► Setting up database...$(RESET)"
	@echo "$(YELLOW)Note: Oracle migrations are manual. Check priv/repo/migrations/$(RESET)"

db.test.setup: ## Set up test database
	@echo "$(CYAN)► Setting up test database...$(RESET)"
	MIX_ENV=test mix run priv/repo/seeds.exs

# ==============================================================================
# Infrastructure Checks
# ==============================================================================

oracle.check: ## Check Oracle connection
	@echo "$(CYAN)► Checking Oracle connection...$(RESET)"
	@if [ -z "$$ORACLE_USER" ]; then \
		echo "$(RED)✗ ORACLE_USER not set$(RESET)"; \
		exit 1; \
	fi
	@if [ -z "$$ORACLE_PASSWORD" ]; then \
		echo "$(RED)✗ ORACLE_PASSWORD not set$(RESET)"; \
		exit 1; \
	fi
	@if [ -z "$$ORACLE_TNS_ALIAS" ]; then \
		echo "$(RED)✗ ORACLE_TNS_ALIAS not set$(RESET)"; \
		exit 1; \
	fi
	@if [ ! -d "$(TNS_ADMIN)" ]; then \
		echo "$(RED)✗ Wallet not found at $(TNS_ADMIN)$(RESET)"; \
		exit 1; \
	fi
	@echo "$(GREEN)✓ Oracle configuration looks good$(RESET)"

keycloak.check: ## Check Keycloak configuration
	@echo "$(CYAN)► Checking Keycloak configuration...$(RESET)"
	@if [ -z "$$KEYCLOAK_BASE_URL" ]; then \
		echo "$(RED)✗ KEYCLOAK_BASE_URL not set$(RESET)"; \
		exit 1; \
	fi
	@if [ -z "$$KEYCLOAK_REALM" ]; then \
		echo "$(RED)✗ KEYCLOAK_REALM not set$(RESET)"; \
		exit 1; \
	fi
	@if [ -z "$$KEYCLOAK_CLIENT_ID" ]; then \
		echo "$(RED)✗ KEYCLOAK_CLIENT_ID not set$(RESET)"; \
		exit 1; \
	fi
	@echo "$(GREEN)✓ Keycloak configuration looks good$(RESET)"

# ==============================================================================
# Release & Docker
# ==============================================================================

release: build ## Build release
	@echo "$(CYAN)► Building release...$(RESET)"
	MIX_ENV=prod mix release
	@echo "$(GREEN)✓ Release built$(RESET)"

docker.build: ## Build Docker image
	@echo "$(CYAN)► Building Docker image...$(RESET)"
	docker build -t $(DOCKER_IMAGE):$(DOCKER_TAG) .
	docker tag $(DOCKER_IMAGE):$(DOCKER_TAG) $(DOCKER_IMAGE):latest
	@echo "$(GREEN)✓ Docker image built: $(DOCKER_IMAGE):$(DOCKER_TAG)$(RESET)"

docker.run: ## Run Docker container
	@echo "$(CYAN)► Running Docker container...$(RESET)"
	@if [ -z "$$SECRET_KEY_BASE" ] && [ -f .secret ]; then \
		SECRET_KEY_BASE=$$(cat .secret); \
	fi; \
	if [ -z "$$SECRET_KEY_BASE" ]; then \
		echo "$(RED)✗ SECRET_KEY_BASE not set. Run 'make docker.secret' first or set SECRET_KEY_BASE env var$(RESET)"; \
		exit 1; \
	fi; \
	docker run -it --rm \
		-p $(PORT):$(PORT) \
		-e PORT=$(PORT) \
		-e SECRET_KEY_BASE="$$SECRET_KEY_BASE" \
		$(DOCKER_IMAGE):$(DOCKER_TAG)

docker.secret: ## Generate a stable secret key (one-time, saves to .secret file)
	@echo "$(CYAN)► Generating secret key...$(RESET)"
	@mix phx.gen.secret > .secret
	@chmod 600 .secret
	@echo "$(GREEN)✓ Secret saved to .secret (add to .gitignore)$(RESET)"

docker.push: ## Push Docker image to registry
	@echo "$(CYAN)► Pushing Docker image...$(RESET)"
	docker push $(DOCKER_IMAGE):$(DOCKER_TAG)
	docker push $(DOCKER_IMAGE):latest
	@echo "$(GREEN)✓ Docker image pushed$(RESET)"

docker.compose.up: ## Start services with docker-compose
	@echo "$(CYAN)► Starting services...$(RESET)"
	docker-compose up -d
	@echo "$(GREEN)✓ Services started$(RESET)"

docker.compose.down: ## Stop services with docker-compose
	@echo "$(CYAN)► Stopping services...$(RESET)"
	docker-compose down
	@echo "$(GREEN)✓ Services stopped$(RESET)"

# ==============================================================================
# Other
# ==============================================================================

clean: ## Clean build artifacts
	@echo "$(CYAN)► Cleaning...$(RESET)"
	rm -rf _build deps .elixir_ls
	rm -rf cover
	rm -rf doc
	@echo "$(GREEN)✓ Cleaned$(RESET)"

docs: ## Generate documentation
	@echo "$(CYAN)► Generating documentation...$(RESET)"
	mix docs
	@echo "$(GREEN)✓ Documentation generated$(RESET)"

# ==============================================================================
# Environment Setup (one-time)
# ==============================================================================

setup: deps ## Initial project setup
	@echo "$(CYAN)► Running initial setup...$(RESET)"
	@mkdir -p priv/wallet
	@mkdir -p priv/plts
	mix compile
	@echo ""
	@echo "$(GREEN)✓ Setup complete!$(RESET)"
	@echo ""
	@echo "$(YELLOW)Next steps:$(RESET)"
	@echo "  1. Copy your Oracle wallet files to priv/wallet/"
	@echo "  2. Set environment variables:"
	@echo "     export ORACLE_WALLET_PATH=\$$(pwd)/priv/wallet"
	@echo "     export ORACLE_TNS_ALIAS=your_db_high"
	@echo "     export ORACLE_USER=your_user"
	@echo "     export ORACLE_PASSWORD=your_password"
	@echo "     export JWT_SECRET=your_jwt_secret"
	@echo "  3. Run 'make dev' to start the development server"
	@echo ""
