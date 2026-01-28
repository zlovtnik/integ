import Config

# Development environment configuration

config :gprint_ex,
  log_claim_details: true,
  oracle_wallet_path: System.get_env("ORACLE_WALLET_PATH", "./priv/wallet")

config :gprint_ex, GprintExWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4000],
  check_origin: false,
  code_reloader: false,
  debug_errors: true,
  secret_key_base: "dev_secret_key_base_change_in_production_min_64_chars_here_1234567890",
  watchers: [],
  server: true

# Do not include metadata nor timestamps in development logs
config :logger, :console,
  format: "[$level] $message\n",
  level: :debug

# Initialize plugs at runtime for faster development compilation
config :phoenix, :plug_init_mode, :runtime
