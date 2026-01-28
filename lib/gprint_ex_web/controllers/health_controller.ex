defmodule GprintExWeb.HealthController do
  @moduledoc """
  Health check endpoints for Kubernetes probes.
  """

  use Phoenix.Controller

  require Logger

  alias GprintEx.Infrastructure.Repo.OracleRepoSupervisor, as: OracleRepo

  @doc "General health check"
  def index(conn, _params) do
    version =
      case Application.spec(:gprint_ex, :vsn) do
        nil -> "unknown"
        vsn -> to_string(vsn)
      end

    conn
    |> put_status(:ok)
    |> json(%{
      status: "healthy",
      service: "gprint_ex",
      version: version,
      timestamp: DateTime.utc_now() |> DateTime.to_iso8601()
    })
  end

  @doc "Readiness probe - checks if service can handle requests"
  def ready(conn, _params) do
    case check_oracle_connection() do
      :ok ->
        conn
        |> put_status(:ok)
        |> json(%{
          status: "ready",
          checks: %{
            oracle: "ok"
          }
        })

      {:error, reason} ->
        # Log the real error internally
        Logger.error("Health check failed - Oracle connection error: #{inspect(reason)}")

        # Return generic error to client
        conn
        |> put_status(:service_unavailable)
        |> json(%{
          status: "not_ready",
          checks: %{
            oracle: "failed"
          },
          error: "oracle_unavailable"
        })
    end
  end

  @doc "Liveness probe - checks if service is alive"
  def live(conn, _params) do
    conn
    |> put_status(:ok)
    |> json(%{status: "alive"})
  end

  defp check_oracle_connection do
    case OracleRepo.query_one("SELECT 1 FROM DUAL", []) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  rescue
    e -> {:error, e}
  end
end
