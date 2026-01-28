defmodule GprintEx.Infrastructure.Repo.OracleRepoSupervisor do
  @moduledoc """
  Supervisor for Oracle database connection pool using wallet authentication.

  Uses DBConnection's built-in pooling (via jamdb_oracle) directly instead of
  wrapping with poolboy - this avoids creating a pool-of-pools.

  Environment Configuration (must be set before app start):
  - ORACLE_WALLET_PATH: Path to wallet directory
  - ORACLE_WALLET_BASE64: Base64 wallet zip (alternative to ORACLE_WALLET_PATH)
  - ORACLE_TNS_ALIAS: TNS alias (e.g., mydb_high)
  - ORACLE_USER: Database username
  - ORACLE_PASSWORD: Database password
  - TNS_ADMIN: Must be set at application startup (see Application module)

  Note: TNS_ADMIN is set once at application startup, not per-worker,
  to avoid race conditions in multi-tenant scenarios.
  """

  use Supervisor

  require Logger

  alias GprintEx.Infrastructure.Repo.OracleConnection
  alias GprintEx.Infrastructure.WalletSetup

  @pool_name GprintEx.OraclePool
  @default_pool_size 2
  # Configurable call timeout (default 30 seconds, use Application.get_env to override)
  @call_timeout Application.compile_env(:gprint_ex, :oracle_call_timeout, 30_000)

  # Client API

  @doc "Start the Oracle connection pool supervisor"
  def start_link(opts \\ []) do
    result = Supervisor.start_link(__MODULE__, opts, name: __MODULE__)

    case result do
      {:ok, pid} ->
        # Only log on genuine first start - check if we've logged before
        # using persistent_term to track across potential code reloads
        unless :persistent_term.get({__MODULE__, :started}, false) do
          pool_size = Keyword.get(opts, :pool_size, @default_pool_size)
          Logger.info("Oracle connection pool ready (#{pool_size} connections)")
          :persistent_term.put({__MODULE__, :started}, true)
        end

        {:ok, pid}

      {:error, {:already_started, pid}} ->
        Logger.debug("OracleRepoSupervisor already started (pid: #{inspect(pid)})")
        {:ok, pid}

      error ->
        Logger.error("OracleRepoSupervisor failed to start: #{inspect(error)}")
        error
    end
  end

  @doc "Execute a query with positional parameters"
  @spec query(String.t(), [term()]) :: {:ok, [map()]} | {:error, term()}
  def query(sql, params \\ []) do
    OracleConnection.query(@pool_name, sql, params, timeout: @call_timeout)
  end

  @doc "Execute a query returning single row"
  @spec query_one(String.t(), [term()]) :: {:ok, map() | nil} | {:error, term()}
  def query_one(sql, params \\ []) do
    case query(sql, params) do
      {:ok, [row | _]} -> {:ok, row}
      {:ok, []} -> {:ok, nil}
      {:error, _} = err -> err
    end
  end

  @doc "Execute an insert/update/delete"
  @spec execute(String.t(), [term()]) :: :ok | {:ok, term()} | {:error, term()}
  def execute(sql, params \\ []) do
    OracleConnection.execute(@pool_name, sql, params, timeout: @call_timeout)
  end

  @doc """
  Execute within a transaction.

  The function receives the connection as an argument so queries can be
  executed on the same connection within the transaction.

  ## Example

      OracleRepoSupervisor.transaction(fn conn ->
        with {:ok, _} <- OracleConnection.execute(conn, insert_sql, params),
             {:ok, rows} <- OracleConnection.query(conn, select_sql, [id]) do
          {:ok, rows}
        end
      end)

  ## Timeout

  The default transaction timeout is #{@call_timeout}ms.
  """
  @spec transaction((DBConnection.conn() -> {:ok, term()} | {:error, term()})) ::
          {:ok, term()} | {:error, term()}
  def transaction(fun) when is_function(fun, 1) do
    OracleConnection.transaction(@pool_name, fun, timeout: @call_timeout)
  end

  # Server callbacks

  @impl true
  def init(opts) do
    pool_size = Keyword.get(opts, :pool_size, @default_pool_size)
    conn_opts = build_connection_config(pool_size)

    children = [
      {OracleConnection, conn_opts}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end

  defp build_connection_config(pool_size) do
    wallet_path =
      case WalletSetup.ensure_wallet() do
        {:ok, path} -> path
        {:error, reason} -> raise "Oracle wallet unavailable: #{inspect(reason)}"
      end

    tns_alias =
      System.get_env("ORACLE_TNS_ALIAS") ||
        raise "ORACLE_TNS_ALIAS not set"

    user =
      System.get_env("ORACLE_USER") ||
        raise "ORACLE_USER not set"

    password =
      System.get_env("ORACLE_PASSWORD") ||
        raise "ORACLE_PASSWORD not set"

    [
      name: @pool_name,
      wallet_path: wallet_path,
      tns_alias: tns_alias,
      user: user,
      password: password,
      pool_size: pool_size
    ]
  end
end
