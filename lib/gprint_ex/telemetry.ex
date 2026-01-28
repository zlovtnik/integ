defmodule GprintEx.Telemetry do
  @moduledoc """
  Telemetry supervisor for metrics and instrumentation.
  """

  use Supervisor

  require Logger

  def start_link(arg) do
    Supervisor.start_link(__MODULE__, arg, name: __MODULE__)
  end

  @impl true
  def init(_arg) do
    children = [
      {:telemetry_poller, measurements: periodic_measurements(), period: 10_000}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end

  defp periodic_measurements do
    [
      {__MODULE__, :measure_memory, []},
      {__MODULE__, :measure_oracle_pool, []}
    ]
  end

  @doc "Emit memory measurements"
  def measure_memory do
    memory = :erlang.memory()

    :telemetry.execute(
      [:gprint_ex, :vm, :memory],
      %{
        total: memory[:total],
        processes: memory[:processes],
        binary: memory[:binary],
        ets: memory[:ets]
      },
      %{}
    )
  end

  @doc "Emit Oracle pool measurements"
  def measure_oracle_pool do
    # DBConnection doesn't expose pool stats directly like poolboy did.
    # For basic health check, we can verify the pool is responsive.
    pool_name = GprintEx.OraclePool

    case Process.whereis(pool_name) do
      nil ->
        :telemetry.execute(
          [:gprint_ex, :oracle, :pool],
          %{
            status: :down,
            available: 0
          },
          %{}
        )

      pid when is_pid(pid) ->
        :telemetry.execute(
          [:gprint_ex, :oracle, :pool],
          %{
            status: :up,
            available: 1
          },
          %{}
        )
    end
  rescue
    e ->
      Logger.error("Failed to get Oracle pool status: #{Exception.message(e)}")

      Logger.debug(
        "Oracle pool status error stacktrace: #{Exception.format_stacktrace(__STACKTRACE__)}"
      )

      :ok
  end
end
