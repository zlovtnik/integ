defmodule GprintEx.MixProject do
  use Mix.Project

  @version "0.1.0"
  @description "Contract Lifecycle Management Service - Functional-First Elixir"

  def project do
    [
      app: :gprint_ex,
      version: @version,
      elixir: "~> 1.15",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      deps: deps(),
      name: "GprintEx",
      description: @description,
      dialyzer: [
        plt_file: {:no_warn, "priv/plts/dialyzer.plt"},
        plt_add_apps: [:mix]
      ]
    ]
  end

  def application do
    [
      mod: {GprintEx.Application, []},
      extra_applications: [:logger, :runtime_tools, :crypto]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      # Web
      # Phoenix 1.7.x series - update to latest patch for security fixes
      {:phoenix, "~> 1.7.18"},
      {:plug_cowboy, "~> 2.6"},
      {:jason, "~> 1.4"},
      {:cors_plug, "~> 3.0"},

      # HTTP Client
      {:finch, "~> 0.16"},

      # Oracle Database
      # Local patched version for OTP 27+/28 SSL socket compatibility fix
      # See: https://github.com/erlangbureau/jamdb_oracle/issues/190
      {:jamdb_oracle, path: "deps_local/jamdb_oracle", override: true},

      # Auth
      # JOSE 1.11.x - latest stable for JWT handling
      {:jose, "~> 1.11.10"},

      # Validation
      {:email_checker, "~> 0.2"},

      # Decimal handling
      {:decimal, "~> 2.1"},

      # Telemetry
      {:telemetry, "~> 1.2"},
      {:telemetry_metrics, "~> 0.6"},
      {:telemetry_poller, "~> 1.0"},

      # Development
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:ex_doc, "~> 0.31", only: :dev, runtime: false},

      # Testing
      {:mox, "~> 1.1", only: :test},
      {:stream_data, "~> 0.6", only: :test}
    ]
  end

  defp aliases do
    [
      setup: ["deps.get"],
      "test.unit": ["test test/domain test/result_test.exs"],
      "test.integration": ["test test/boundaries test/infrastructure"],
      check: ["format --check-formatted", "credo --strict", "dialyzer"]
    ]
  end
end
