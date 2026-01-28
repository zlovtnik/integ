defmodule GprintEx.Application do
  @moduledoc """
  OTP Application for GprintEx Contract Lifecycle Management.

  Starts supervision tree with:
  - Finch HTTP client
  - Oracle connection pool
  - Phoenix endpoint
  - Telemetry
  """

  use Application

  require Logger

  @impl true
  def start(_type, _args) do
    # Set TNS_ADMIN for Oracle wallet ONCE at startup to avoid race conditions
    set_oracle_tns_admin()

    children = [
      # PubSub for Phoenix (required if configured in endpoint)
      {Phoenix.PubSub, name: GprintEx.PubSub},

      # Telemetry supervisor
      GprintEx.Telemetry,

      # HTTP client for Keycloak
      {Finch, name: GprintEx.Finch},

      # Oracle connection pool
      GprintEx.Infrastructure.Repo.OracleRepoSupervisor,

      # Phoenix endpoint
      GprintExWeb.Endpoint
    ]

    opts = [strategy: :one_for_one, name: GprintEx.Supervisor]

    Supervisor.start_link(children, opts)
  end

  @impl true
  def config_change(changed, _new, removed) do
    GprintExWeb.Endpoint.config_change(changed, removed)
    :ok
  end

  # Set TNS_ADMIN environment variable for Oracle wallet location
  # Must be done once at startup, not per-worker
  defp set_oracle_tns_admin do
    wallet_path =
      Application.get_env(:gprint_ex, :oracle_wallet_path) ||
        System.get_env("ORACLE_WALLET_PATH")

    # Normalize: treat empty or whitespace-only strings as nil
    normalized_path =
      case wallet_path do
        nil ->
          nil

        path when is_binary(path) ->
          trimmed = String.trim(path)
          if trimmed == "", do: nil, else: trimmed

        other ->
          other
      end

    if normalized_path do
      System.put_env("TNS_ADMIN", normalized_path)
      Logger.info("Oracle TNS_ADMIN set to: #{normalized_path}")
    else
      Logger.warning("ORACLE_WALLET_PATH not configured - Oracle connections may fail")
    end
  end
end
