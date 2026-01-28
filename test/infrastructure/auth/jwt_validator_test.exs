defmodule GprintEx.Infrastructure.Auth.JwtValidatorTest do
  # NOTE: async: false because setup mutates global System.put_env("JWT_SECRET", ...)
  # If you refactor JwtValidator to accept config injection, this can be async: true
  use ExUnit.Case, async: false

  alias GprintEx.Infrastructure.Auth.JwtValidator

  # Test secret for JWT generation
  @test_secret "test_jwt_secret_for_testing_only_32_chars_min"

  setup do
    # Set test secret
    System.put_env("JWT_SECRET", @test_secret)
    on_exit(fn -> System.delete_env("JWT_SECRET") end)
    :ok
  end

  describe "validate/1" do
    test "validates a valid token" do
      claims = %{
        "user" => "testuser",
        "tenant_id" => "tenant-1",
        "login_session" => "session-123",
        "exp" => System.system_time(:second) + 3600,
        "iat" => System.system_time(:second)
      }

      token = generate_token(claims)

      assert {:ok, validated} = JwtValidator.validate(token)
      assert validated.user == "testuser"
      assert validated.tenant_id == "tenant-1"
      assert validated.login_session == "session-123"
    end

    test "rejects expired token" do
      claims = %{
        "user" => "testuser",
        "tenant_id" => "tenant-1",
        "login_session" => "session-123",
        "exp" => System.system_time(:second) - 3600,
        "iat" => System.system_time(:second) - 7200
      }

      token = generate_token(claims)

      assert {:error, :expired} = JwtValidator.validate(token)
    end

    test "rejects token with missing claims" do
      claims = %{
        "user" => "testuser",
        # missing tenant_id and login_session
        "exp" => System.system_time(:second) + 3600,
        "iat" => System.system_time(:second)
      }

      token = generate_token(claims)

      assert {:error, :missing_claims} = JwtValidator.validate(token)
    end

    test "rejects invalid token" do
      assert {:error, :invalid_token} = JwtValidator.validate("invalid.token.here")
    end

    test "rejects non-string input" do
      assert {:error, :invalid_token} = JwtValidator.validate(nil)
      assert {:error, :invalid_token} = JwtValidator.validate(123)
    end
  end

  describe "peek/1" do
    test "extracts claims without verification" do
      claims = %{
        "user" => "testuser",
        "tenant_id" => "tenant-1"
      }

      token = generate_token(claims)

      assert {:ok, peeked} = JwtValidator.peek(token)
      assert peeked["user"] == "testuser"
      assert peeked["tenant_id"] == "tenant-1"
    end

    test "returns error for invalid token structure" do
      assert {:error, :invalid_token} = JwtValidator.peek("not-a-jwt")
    end
  end

  # Helper to generate test tokens
  defp generate_token(claims) do
    jwk = %JOSE.JWK{kty: {:oct, @test_secret}}
    jws = %{"alg" => "HS256"}

    {_, token} =
      JOSE.JWT.sign(jwk, jws, claims)
      |> JOSE.JWS.compact()

    token
  end
end
