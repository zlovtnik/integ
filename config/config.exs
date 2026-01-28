import Config

# Base configuration for all environments

config :gprint_ex,
  namespace: GprintEx,
  # Oracle timezone assumption (see OracleWorker for details)
  oracle_timezone: "Etc/UTC",
  # Log claim details at debug level (disable in prod)
  log_claim_details: false

# Phoenix endpoint configuration
config :gprint_ex, GprintExWeb.Endpoint,
  url: [host: "localhost"],
  render_errors: [
    formats: [json: GprintExWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: GprintEx.PubSub

# JSON library
config :phoenix, :json_library, Jason

# Logger configuration
config :logger, :console,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id, :tenant_id, :user]

# Import environment specific config
import_config "#{config_env()}.exs"
