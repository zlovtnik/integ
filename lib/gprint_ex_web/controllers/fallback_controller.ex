defmodule GprintExWeb.FallbackController do
  @moduledoc """
  Fallback controller for handling errors consistently.
  """

  use Phoenix.Controller

  require Logger

  # Handle bare :not_found atom (from router)
  def call(conn, :not_found) do
    conn
    |> put_status(:not_found)
    |> put_view(GprintExWeb.ErrorJSON)
    |> render(:error, code: "NOT_FOUND", message: "Endpoint not found")
  end

  def call(conn, {:error, :not_found}) do
    conn
    |> put_status(:not_found)
    |> put_view(GprintExWeb.ErrorJSON)
    |> render(:error, code: "NOT_FOUND", message: "Resource not found")
  end

  def call(conn, {:error, :validation_failed, errors}) do
    conn
    |> put_status(:unprocessable_entity)
    |> put_view(GprintExWeb.ErrorJSON)
    |> render("validation_error.json", errors: errors)
  end

  def call(conn, {:error, :invalid_transition}) do
    conn
    |> put_status(:unprocessable_entity)
    |> put_view(GprintExWeb.ErrorJSON)
    |> render(:error, code: "INVALID_TRANSITION", message: "Status transition not allowed")
  end

  def call(conn, {:error, :unauthorized}) do
    conn
    |> put_status(:unauthorized)
    |> put_view(GprintExWeb.ErrorJSON)
    |> render(:error, code: "UNAUTHORIZED", message: "Not authorized")
  end

  def call(conn, {:error, reason}) do
    # Log the real error server-side for debugging
    Logger.error("Internal error in request: #{inspect(reason)}")

    # Return generic message to client (don't leak internals)
    conn
    |> put_status(:internal_server_error)
    |> put_view(GprintExWeb.ErrorJSON)
    |> render(:error, code: "INTERNAL_ERROR", message: "An internal error occurred")
  end

  def not_found(conn, _params) do
    conn
    |> put_status(:not_found)
    |> put_view(GprintExWeb.ErrorJSON)
    |> render(:error, code: "NOT_FOUND", message: "Endpoint not found")
  end
end
