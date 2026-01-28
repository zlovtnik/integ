defmodule GprintEx.Infrastructure.Auth.KeycloakClient do
  @moduledoc """
  Keycloak OAuth2 client for token operations.

  Supports:
  - Authorization Code + PKCE flow (recommended)
  - Token refresh
  - Token introspection
  - User info retrieval

  Configuration (environment variables):
  - KEYCLOAK_BASE_URL: e.g., https://keycloak.example.com
  - KEYCLOAK_REALM: e.g., master
  - KEYCLOAK_CLIENT_ID: e.g., gprint-client
  - KEYCLOAK_CLIENT_SECRET: (optional, for confidential clients)
  """

  require Logger

  @type config :: %{
          base_url: String.t(),
          realm: String.t(),
          client_id: String.t(),
          client_secret: String.t() | nil
        }

  @type token_response :: %{
          access_token: String.t(),
          refresh_token: String.t() | nil,
          expires_in: pos_integer(),
          token_type: String.t()
        }

  @type pkce :: %{
          code_verifier: String.t(),
          code_challenge: String.t(),
          code_challenge_method: String.t()
        }

  # Public API

  @doc "Generate PKCE challenge for authorization code flow"
  @spec generate_pkce() :: {:ok, pkce()}
  def generate_pkce do
    verifier_bytes = :crypto.strong_rand_bytes(32)
    code_verifier = Base.url_encode64(verifier_bytes, padding: false)

    code_challenge =
      :crypto.hash(:sha256, code_verifier)
      |> Base.url_encode64(padding: false)

    {:ok,
     %{
       code_verifier: code_verifier,
       code_challenge: code_challenge,
       code_challenge_method: "S256"
     }}
  end

  @doc "Build authorization URL for OAuth2 flow"
  @spec authorization_url(String.t(), String.t(), pkce()) :: String.t()
  def authorization_url(redirect_uri, state, pkce) do
    config = get_config()

    params =
      URI.encode_query(%{
        "client_id" => config.client_id,
        "response_type" => "code",
        "scope" => "openid profile email",
        "redirect_uri" => redirect_uri,
        "state" => state,
        "code_challenge" => pkce.code_challenge,
        "code_challenge_method" => pkce.code_challenge_method
      })

    "#{authorization_endpoint(config)}?#{params}"
  end

  @doc "Exchange authorization code for tokens"
  @spec exchange_code(String.t(), String.t(), String.t()) ::
          {:ok, token_response()} | {:error, term()}
  def exchange_code(code, redirect_uri, code_verifier) do
    config = get_config()

    body =
      %{
        "grant_type" => "authorization_code",
        "client_id" => config.client_id,
        "code" => code,
        "redirect_uri" => redirect_uri,
        "code_verifier" => code_verifier
      }
      |> maybe_add_client_secret(config)
      |> URI.encode_query()

    post_token_request(config, body)
  end

  @doc "Refresh access token"
  @spec refresh_token(String.t()) :: {:ok, token_response()} | {:error, term()}
  def refresh_token(refresh_token) do
    config = get_config()

    body =
      %{
        "grant_type" => "refresh_token",
        "client_id" => config.client_id,
        "refresh_token" => refresh_token
      }
      |> maybe_add_client_secret(config)
      |> URI.encode_query()

    post_token_request(config, body)
  end

  @doc "Introspect token (validate with Keycloak)"
  @spec introspect(String.t()) :: {:ok, map()} | {:error, term()}
  def introspect(token) do
    config = get_config()

    body =
      %{
        "token" => token,
        "client_id" => config.client_id
      }
      |> maybe_add_client_secret(config)
      |> URI.encode_query()

    case http_post(introspect_endpoint(config), body) do
      {:ok, %{"active" => true} = response} -> {:ok, response}
      {:ok, %{"active" => false}} -> {:error, :token_inactive}
      {:error, _} = err -> err
    end
  end

  @doc "Get user info from Keycloak"
  @spec get_user_info(String.t()) :: {:ok, map()} | {:error, term()}
  def get_user_info(access_token) do
    config = get_config()
    http_get(userinfo_endpoint(config), access_token)
  end

  @doc "Logout (invalidate refresh token)"
  @spec logout(String.t()) :: :ok | {:error, term()}
  def logout(refresh_token) do
    config = get_config()

    body =
      %{
        "client_id" => config.client_id,
        "refresh_token" => refresh_token
      }
      |> maybe_add_client_secret(config)
      |> URI.encode_query()

    case http_post(logout_endpoint(config), body) do
      {:ok, _} -> :ok
      {:error, _} = err -> err
    end
  end

  # Private

  defp get_config do
    %{
      base_url:
        System.get_env("KEYCLOAK_BASE_URL") ||
          raise("KEYCLOAK_BASE_URL not set"),
      realm:
        System.get_env("KEYCLOAK_REALM") ||
          raise("KEYCLOAK_REALM not set"),
      client_id:
        System.get_env("KEYCLOAK_CLIENT_ID") ||
          raise("KEYCLOAK_CLIENT_ID not set"),
      client_secret: System.get_env("KEYCLOAK_CLIENT_SECRET")
    }
  end

  defp token_endpoint(%{base_url: url, realm: realm}) do
    "#{String.trim_trailing(url, "/")}/realms/#{realm}/protocol/openid-connect/token"
  end

  defp authorization_endpoint(%{base_url: url, realm: realm}) do
    "#{String.trim_trailing(url, "/")}/realms/#{realm}/protocol/openid-connect/auth"
  end

  defp userinfo_endpoint(%{base_url: url, realm: realm}) do
    "#{String.trim_trailing(url, "/")}/realms/#{realm}/protocol/openid-connect/userinfo"
  end

  defp introspect_endpoint(%{base_url: url, realm: realm}) do
    "#{String.trim_trailing(url, "/")}/realms/#{realm}/protocol/openid-connect/token/introspect"
  end

  defp logout_endpoint(%{base_url: url, realm: realm}) do
    "#{String.trim_trailing(url, "/")}/realms/#{realm}/protocol/openid-connect/logout"
  end

  defp maybe_add_client_secret(params, %{client_secret: nil}), do: params
  defp maybe_add_client_secret(params, %{client_secret: ""}), do: params

  defp maybe_add_client_secret(params, %{client_secret: secret}) do
    Map.put(params, "client_secret", secret)
  end

  defp post_token_request(config, body) do
    case http_post(token_endpoint(config), body) do
      {:ok, response} ->
        # Validate required fields exist and have expected types
        with {:ok, access_token} <- validate_string_field(response, "access_token"),
             {:ok, token_type} <- validate_string_field(response, "token_type"),
             {:ok, expires_in} <- validate_integer_field(response, "expires_in") do
          {:ok,
           %{
             access_token: access_token,
             refresh_token: response["refresh_token"],
             expires_in: expires_in,
             token_type: token_type
           }}
        else
          {:error, reason} ->
            Logger.error("Invalid token response from Keycloak: #{inspect(reason)}")
            {:error, {:invalid_token_response, reason}}
        end

      {:error, _} = err ->
        err
    end
  end

  defp validate_string_field(response, field) do
    case response[field] do
      nil -> {:error, {:missing_field, field}}
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, {:invalid_field_type, field}}
    end
  end

  defp validate_integer_field(response, field) do
    case response[field] do
      nil -> {:error, {:missing_field, field}}
      value when is_integer(value) and value > 0 -> {:ok, value}
      _ -> {:error, {:invalid_field_type, field}}
    end
  end

  defp http_post(url, body) do
    headers = [{"content-type", "application/x-www-form-urlencoded"}]

    case Finch.build(:post, url, headers, body)
         |> Finch.request(GprintEx.Finch, receive_timeout: 15_000) do
      {:ok, %{status: 200, body: body}} ->
        Jason.decode(body)

      {:ok, %{status: status, body: body}} ->
        Logger.error("Keycloak request failed with status #{status}")
        Logger.debug("Keycloak response body (debug only): #{truncate_body(body)}")
        {:error, {:http_error, status}}

      {:error, reason} ->
        Logger.error("Keycloak request failed: connection error")
        Logger.debug("Keycloak connection error details: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp truncate_body(body) when byte_size(body) > 500 do
    String.slice(body, 0, 500) <> "... [truncated]"
  end

  defp truncate_body(body), do: body

  defp http_get(url, access_token) do
    headers = [{"authorization", "Bearer #{access_token}"}]

    case Finch.build(:get, url, headers)
         |> Finch.request(GprintEx.Finch, receive_timeout: 15_000) do
      {:ok, %{status: 200, body: body}} ->
        Jason.decode(body)

      {:ok, %{status: status, body: body}} ->
        Logger.error("Keycloak userinfo failed: #{status} - #{truncate_body(body)}")
        {:error, {:http_error, status}}

      {:error, reason} ->
        Logger.error("Keycloak userinfo failed: connection error")
        Logger.debug("Keycloak connection error details: #{inspect(reason)}")
        {:error, reason}
    end
  end
end
