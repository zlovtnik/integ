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
  end

  # Catch-all for 404 - inside api scope to go through :api pipeline
  scope "/", GprintExWeb do
    pipe_through :api

    match :*, "/*path", FallbackController, :not_found
  end
end
