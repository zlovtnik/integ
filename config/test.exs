import Config

# Test environment configuration

config :gprint_ex,
  log_claim_details: true,
  oracle_wallet_path: "./priv/wallet"

config :gprint_ex, GprintExWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "test_secret_key_base_for_testing_only_change_in_production_64_chars_min",
  server: false

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime
