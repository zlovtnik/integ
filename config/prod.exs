import Config

# Production configuration
# Most values come from runtime.exs via environment variables

config :gprint_ex, GprintExWeb.Endpoint,
  cache_static_manifest: "priv/static/cache_manifest.json",
  server: true

# Do not print debug messages in production
config :logger, level: :info

# Runtime production configuration is handled in config/runtime.exs
