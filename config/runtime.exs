import Config

# Runtime configuration loaded at boot time
# This file is evaluated after compilation, so you can use System.get_env

if config_env() == :prod do
  # Oracle Database configuration
  oracle_wallet_path =
    System.get_env("ORACLE_WALLET_PATH") ||
      raise "ORACLE_WALLET_PATH environment variable is required"

  config :gprint_ex,
    oracle_wallet_path: oracle_wallet_path,
    log_claim_details: false

  # Phoenix endpoint
  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise "SECRET_KEY_BASE environment variable is required"

  host = System.get_env("PHX_HOST") || "localhost"
  port = String.to_integer(System.get_env("PORT") || "4000")

  live_view_signing_salt =
    System.get_env("LIVE_VIEW_SIGNING_SALT") ||
      raise "LIVE_VIEW_SIGNING_SALT environment variable is required for production"

  config :gprint_ex, GprintExWeb.Endpoint,
    url: [host: host, port: 443, scheme: "https"],
    http: [
      ip: {0, 0, 0, 0, 0, 0, 0, 0},
      port: port
    ],
    secret_key_base: secret_key_base,
    live_view: [signing_salt: live_view_signing_salt],
    server: true
end

# Keycloak configuration (all environments)
if System.get_env("KEYCLOAK_BASE_URL") do
  config :gprint_ex, :keycloak,
    base_url: System.get_env("KEYCLOAK_BASE_URL"),
    realm: System.get_env("KEYCLOAK_REALM"),
    client_id: System.get_env("KEYCLOAK_CLIENT_ID"),
    client_secret: System.get_env("KEYCLOAK_CLIENT_SECRET")
end
