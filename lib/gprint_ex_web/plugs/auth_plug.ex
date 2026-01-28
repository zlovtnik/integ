defmodule GprintExWeb.Plugs.AuthPlug do
  @moduledoc """
  Authentication plug that validates JWT and extracts tenant context.

  Adds to conn.assigns:
  - :current_user (string)
  - :tenant_id (string)
  - :login_session (string)
  - :auth_claims (full claims map)
  """

  import Plug.Conn
  alias GprintEx.Infrastructure.Auth.JwtValidator

  @behaviour Plug

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    with {:ok, token} <- extract_token(conn),
         {:ok, claims} <- JwtValidator.validate(token) do
      conn
      |> assign(:current_user, claims.user)
      |> assign(:tenant_id, claims.tenant_id)
      |> assign(:login_session, claims.login_session)
      |> assign(:auth_claims, claims)
    else
      {:error, reason} ->
        conn
        |> put_status(:unauthorized)
        |> Phoenix.Controller.put_view(GprintExWeb.ErrorJSON)
        |> Phoenix.Controller.render(:error,
          code: "UNAUTHORIZED",
          message: auth_error_message(reason)
        )
        |> halt()
    end
  end

  @doc "Build tenant context from conn.assigns"
  @spec tenant_context(Plug.Conn.t()) :: map()
  def tenant_context(conn) do
    %{
      tenant_id: conn.assigns[:tenant_id],
      user: conn.assigns[:current_user],
      login_session: conn.assigns[:login_session]
    }
  end

  defp extract_token(conn) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> token] -> {:ok, String.trim(token)}
      _ -> {:error, :missing_token}
    end
  end

  defp auth_error_message(:invalid_token), do: "Invalid authentication token"
  defp auth_error_message(:expired), do: "Authentication token has expired"
  defp auth_error_message(:missing_claims), do: "Token missing required claims"
  defp auth_error_message(:missing_token), do: "Authorization header required"
  defp auth_error_message(_), do: "Authentication failed"
end
