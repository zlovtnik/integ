defmodule GprintEx.Infrastructure.Auth.JwtValidator do
  @moduledoc """
  JWT token validation using HS256 (symmetric key).
  Tokens issued by external auth service (Keycloak via Rust/Actix-Web).

  Expected Claims:
  - user: username/identifier
  - tenant_id: tenant isolation key
  - login_session: session identifier
  """

  require Logger

  @type claims :: %{
          user: String.t(),
          tenant_id: String.t(),
          login_session: String.t(),
          exp: pos_integer(),
          iat: pos_integer() | nil
        }

  @doc "Validate JWT token and extract claims"
  @spec validate(String.t()) ::
          {:ok, claims()} | {:error, :invalid_token | :expired | :missing_claims}
  def validate(token) when is_binary(token) do
    secret = jwt_secret()

    with {:ok, claims} <- decode_and_verify(token, secret),
         :ok <- validate_expiry(claims),
         :ok <- validate_required_claims(claims) do
      {:ok, normalize_claims(claims)}
    end
  end

  def validate(_), do: {:error, :invalid_token}

  @doc "Extract claims without verification (for logging/debugging only)"
  @spec peek(String.t()) :: {:ok, map()} | {:error, :invalid_token}
  def peek(token) do
    case String.split(token, ".") do
      [_header, payload, _sig] ->
        case Base.url_decode64(payload, padding: false) do
          {:ok, json} ->
            case Jason.decode(json) do
              {:ok, decoded} -> {:ok, decoded}
              {:error, _} -> {:error, :invalid_token}
            end

          :error ->
            {:error, :invalid_token}
        end

      _ ->
        {:error, :invalid_token}
    end
  end

  # Private

  defp jwt_secret do
    System.get_env("JWT_SECRET") ||
      raise "JWT_SECRET environment variable is not set"
  end

  defp decode_and_verify(token, secret) do
    jwk = %JOSE.JWK{kty: {:oct, secret}}

    case JOSE.JWT.verify_strict(jwk, ["HS256"], token) do
      {true, %JOSE.JWT{fields: claims}, _jws} ->
        {:ok, claims}

      {false, _, _} ->
        {:error, :invalid_token}
    end
  rescue
    _ -> {:error, :invalid_token}
  end

  # Clock skew tolerance in seconds (configurable via :gprint_ex, :jwt_clock_skew)
  # Default: 30 seconds to handle minor time drift between servers
  defp validate_expiry(%{"exp" => exp}) when is_integer(exp) do
    now = System.system_time(:second)
    skew = Application.get_env(:gprint_ex, :jwt_clock_skew, 30)
    if exp + skew > now, do: :ok, else: {:error, :expired}
  end

  defp validate_expiry(_), do: {:error, :expired}

  defp validate_required_claims(claims) do
    required = ["user", "tenant_id", "login_session"]
    missing = Enum.filter(required, &(is_nil(claims[&1]) or claims[&1] == ""))

    if Enum.empty?(missing) do
      :ok
    else
      Logger.warning("JWT missing required claim(s)")

      if Application.get_env(:gprint_ex, :log_claim_details, false) do
        Logger.debug("JWT validation: missing claims detail", missing: inspect(missing))
      end

      {:error, :missing_claims}
    end
  end

  defp normalize_claims(claims) do
    %{
      user: claims["user"],
      tenant_id: claims["tenant_id"],
      login_session: claims["login_session"],
      exp: claims["exp"],
      iat: claims["iat"]
    }
  end
end
