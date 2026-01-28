defmodule GprintExWeb.Router do
  @moduledoc """
  Router for the GprintEx API.
  """

  use Phoenix.Router

  pipeline :api do
    plug :accepts, ["json"]
    plug GprintExWeb.Plugs.RequestIdPlug
  end

  pipeline :authenticated do
    plug GprintExWeb.Plugs.AuthPlug
  end

  # Health check (no auth)
  scope "/api", GprintExWeb do
    pipe_through :api

    get "/health", HealthController, :index
    get "/health/ready", HealthController, :ready
    get "/health/live", HealthController, :live
  end

  # Protected API routes
  scope "/api/v1", GprintExWeb do
    pipe_through [:api, :authenticated]

    # Customers
    resources "/customers", CustomerController, except: [:new, :edit]

    # Contracts
    resources "/contracts", ContractController, except: [:new, :edit] do
      # Contract items as nested resource
      resources "/items", ContractItemController, except: [:new, :edit]
    end

    # Contract status transitions (uses :contract_id to match nested resource param naming)
    post "/contracts/:contract_id/transition", ContractController, :transition

    # Services catalog
    resources "/services", ServiceController, except: [:new, :edit]

    # Document generation (uses :contract_id to match nested resource param naming)
    post "/contracts/:contract_id/generate", GenerationController, :generate
    get "/contracts/:contract_id/document", GenerationController, :download

    # =============================================================================
    # ETL / Batch Processing
    # =============================================================================

    # ETL Sessions - staging session lifecycle
    get "/etl/sessions", ETLSessionController, :index
    post "/etl/sessions", ETLSessionController, :create
    get "/etl/sessions/:id", ETLSessionController, :show
    delete "/etl/sessions/:id", ETLSessionController, :delete

    # ETL Session operations
    post "/etl/sessions/:id/load", ETLSessionController, :load
    post "/etl/sessions/:id/transform", ETLSessionController, :transform
    post "/etl/sessions/:id/validate", ETLSessionController, :validate
    post "/etl/sessions/:id/promote", ETLSessionController, :promote

    # ETL maintenance
    post "/etl/cleanup", ETLSessionController, :cleanup

    # =============================================================================
    # ETL Pipelines
    # =============================================================================

    # Pipeline templates and execution
    get "/pipelines/templates", PipelineController, :templates
    post "/pipelines/:name/run", PipelineController, :run
    get "/pipelines/status/:session_id", PipelineController, :status
    delete "/pipelines/:session_id", PipelineController, :cancel

    # =============================================================================
    # Integration / EIP Message Management
    # =============================================================================

    # Message submission and processing
    post "/integration/messages", IntegrationMessageController, :create
    post "/integration/messages/transform", IntegrationMessageController, :transform
    post "/integration/messages/check-duplicate", IntegrationMessageController, :check_duplicate
    post "/integration/messages/:id/processed", IntegrationMessageController, :mark_processed
    post "/integration/messages/:id/retry", IntegrationMessageController, :retry
    post "/integration/messages/:id/dead-letter", IntegrationMessageController, :dead_letter

    # Routing rules
    get "/integration/routing-rules", IntegrationMessageController, :routing_rules

    # Message aggregation (scatter-gather, aggregator patterns)
    post "/integration/aggregations", IntegrationMessageController, :start_aggregation
    post "/integration/aggregations/:id/messages", IntegrationMessageController, :add_to_aggregation
    post "/integration/aggregations/:id/complete", IntegrationMessageController, :complete_aggregation

    # =============================================================================
    # Message Channels (monitoring/debugging)
    # =============================================================================

    get "/channels", ChannelController, :index
    post "/channels", ChannelController, :create
    get "/channels/:name", ChannelController, :show
    post "/channels/:name/drain", ChannelController, :drain
  end

  # Catch-all for 404 - inside api scope to go through :api pipeline
  scope "/", GprintExWeb do
    pipe_through :api

    match :*, "/*path", FallbackController, :not_found
  end
end
