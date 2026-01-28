defmodule GprintEx.Infrastructure.Repo.OracleConnection do
  @moduledoc """
  Oracle connection pool using jamdb_oracle's DBConnection-based pooling.

  This module provides a clean interface over Jamdb.Oracle, handling:
  - Connection options building from config
  - Query result mapping to Elixir maps
  - Oracle type normalization (timestamps, CLOBs, etc.)
  - Transaction support with proper savepoint handling
  """

  require Logger

  @oracle_timezone Application.compile_env(:gprint_ex, :oracle_timezone, "Etc/UTC")

  @doc """
  Start the connection pool as a supervised child.

  Options:
  - `:name` - Pool name (required)
  - `:wallet_path` - Path to Oracle wallet directory (required)
  - `:tns_alias` - TNS alias to connect to (required)
  - `:user` - Database username (required)
  - `:password` - Database password (required)
  - `:pool_size` - Number of connections (default: 10)
  - `:hostname` - Oracle host (optional, extracted from TNS description if not provided)
  """
  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      type: :worker,
      shutdown: 5_000
    }
  end

  def start_link(opts) do
    name = Keyword.fetch!(opts, :name)
    wallet_path = Keyword.fetch!(opts, :wallet_path)
    tns_alias = Keyword.fetch!(opts, :tns_alias)
    user = Keyword.fetch!(opts, :user)
    password = Keyword.fetch!(opts, :password)
    pool_size = Keyword.get(opts, :pool_size, 10)

    # Read TNS description from tnsnames.ora
    description = read_tns_description(wallet_path, tns_alias)

    # Extract hostname from opts or derive from TNS description
    hostname = Keyword.get(opts, :hostname) || extract_host_from_description(description)

    # SSL options for Oracle ADB with wallet authentication
    # NOTE: Using verify: :verify_none due to jamdb_oracle limitation with Oracle wallet
    # authentication. Oracle ADB wallets use cwallet.sso which contains both the client
    # certificate and CA chain in a proprietary format that Erlang :ssl cannot parse
    # directly as a CA cert file. Proper verification would require extracting CA certs
    # to PEM format. See: https://github.com/erlangbureau/jamdb_oracle/issues/190
    # TODO: Extract CA certs from wallet to truststore.pem and enable :verify_peer
    ssl_opts = [
      cacertfile: Path.join(wallet_path, "cwallet.sso"),
      verify: :verify_none
    ]

    if Application.get_env(:gprint_ex, :warn_insecure_ssl, true) do
      Logger.warning("Oracle connection using verify: :verify_none - SSL certificate validation disabled")
    end

    # Build jamdb_oracle connection options
    # IMPORTANT: Both 'description' and 'ssl' must be passed via 'parameters' option
    # because the Elixir wrapper only forwards 'parameters' to the Erlang layer
    conn_opts = [
      name: name,
      hostname: hostname,
      port: 1522,
      database: tns_alias,
      username: user,
      password: password,
      timeout: 30_000,
      pool_size: pool_size,
      # Pass description and ssl through parameters - forwarded to erlang layer
      parameters: [
        description: description,
        ssl: ssl_opts
      ]
    ]

    # Simply start the pool - DBConnection handles name registration
    case DBConnection.start_link(Jamdb.Oracle, conn_opts) do
      {:ok, pid} ->
        {:ok, pid}

      {:error, {:already_started, pid}} ->
        {:ok, pid}

      {:error, reason} = error ->
        Logger.error("Failed to start Oracle connection pool: #{inspect(reason)}")
        error
    end
  end

  @doc """
  Execute a query and return results as a list of maps.
  """
  @spec query(DBConnection.conn() | GenServer.name(), String.t(), [term()], keyword()) ::
          {:ok, [map()]} | {:error, term()}
  def query(conn, sql, params \\ [], opts \\ []) do
    query_struct = %Jamdb.Oracle.Query{statement: sql, name: "", batch: false}

    case DBConnection.prepare_execute(conn, query_struct, params, opts) do
      {:ok, _query, %{columns: columns, rows: rows}} ->
        mapped =
          Enum.map(rows, fn row ->
            columns
            |> Enum.zip(row)
            |> Map.new(fn {col, val} ->
              {String.downcase(col) |> String.to_atom(), normalize_value(val)}
            end)
          end)

        {:ok, mapped}

      {:ok, _query, result} ->
        # Handle non-SELECT results
        {:ok, result}

      {:error, reason} ->
        Logger.error("Query failed: #{inspect(reason)}")
        {:error, {:query_failed, reason}}
    end
  end

  @doc """
  Execute an insert/update/delete statement.
  """
  @spec execute(DBConnection.conn() | GenServer.name(), String.t(), [term()], keyword()) ::
          :ok | {:ok, term()} | {:error, term()}
  def execute(conn, sql, params \\ [], opts \\ []) do
    query_struct = %Jamdb.Oracle.Query{statement: sql, name: "", batch: false}

    case DBConnection.prepare_execute(conn, query_struct, params, opts) do
      {:ok, _query, %{num_rows: _}} -> :ok
      {:ok, _query, %{returning: [id]}} when not is_list(id) -> {:ok, id}
      {:ok, _query, %{returning: [[id]]}} -> {:ok, id}
      {:ok, _query, %{returning: returning}} -> {:ok, returning}
      {:error, reason} -> {:error, {:execute_failed, reason}}
    end
  end

  @doc """
  Execute a function within a transaction.

  Uses Oracle savepoints for rollback support.
  """
  @spec transaction(
          DBConnection.conn() | GenServer.name(),
          (DBConnection.conn() -> term()),
          keyword()
        ) ::
          {:ok, term()} | {:error, term()}
  def transaction(conn, fun, opts \\ []) when is_function(fun, 1) do
    DBConnection.run(
      conn,
      fn conn_pid ->
        with :ok <- execute_simple(conn_pid, "SAVEPOINT txn_start", opts) do
          try do
            case fun.(conn_pid) do
              {:ok, value} ->
                case execute_simple(conn_pid, "COMMIT", opts) do
                  :ok ->
                    {:ok, value}

                  {:error, commit_reason} ->
                    Logger.error("Transaction COMMIT failed: #{inspect(commit_reason)}")
                    # Attempt rollback to restore clean connection state
                    _ = execute_simple(conn_pid, "ROLLBACK TO txn_start", opts)
                    {:error, {:commit_failed, commit_reason}}
                end

              {:error, reason} ->
                case execute_simple(conn_pid, "ROLLBACK TO txn_start", opts) do
                  :ok ->
                    {:error, reason}

                  {:error, rollback_reason} ->
                    Logger.error("Transaction ROLLBACK failed: #{inspect(rollback_reason)}")
                    {:error, {:rollback_failed, reason, rollback_reason}}
                end

              returned_value ->
                Logger.error(
                  "Transaction function returned unexpected value: #{inspect(returned_value)}"
                )

                _ = execute_simple(conn_pid, "ROLLBACK TO txn_start", opts)
                {:error, {:invalid_return, returned_value}}
            end
          rescue
            e ->
              stacktrace = __STACKTRACE__

              Logger.error(
                "Transaction raised exception: #{Exception.format(:error, e, stacktrace)}"
              )

              _ = execute_simple(conn_pid, "ROLLBACK TO txn_start", opts)
              {:error, {:exception, e, stacktrace}}
          end
        end
      end,
      opts
    )
  end

  # Private functions

  defp execute_simple(conn, sql, opts) do
    query_struct = %Jamdb.Oracle.Query{statement: sql, name: "", batch: false}

    case DBConnection.prepare_execute(conn, query_struct, [], opts) do
      {:ok, _query, _result} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  # Oracle type normalization
  defp normalize_value(nil), do: nil
  defp normalize_value({:datetime, dt}), do: NaiveDateTime.from_erl!(dt)

  defp normalize_value({:timestamp, ts}) do
    naive = NaiveDateTime.from_erl!(ts)

    case DateTime.from_naive(naive, @oracle_timezone) do
      {:ok, dt} -> dt
      {:error, _} -> DateTime.from_naive!(naive, "Etc/UTC")
    end
  end

  defp normalize_value({:clob, data}), do: data
  defp normalize_value(val), do: val

  # Read TNS description from tnsnames.ora for the given alias
  defp read_tns_description(wallet_path, tns_alias) do
    tnsnames_path = Path.join(wallet_path, "tnsnames.ora")

    case File.read(tnsnames_path) do
      {:ok, content} ->
        parse_tns_entry(content, tns_alias)

      {:error, reason} ->
        raise "Failed to read tnsnames.ora from #{tnsnames_path}: #{inspect(reason)}"
    end
  end

  # Extract hostname from TNS description string
  # Parses patterns like: (host=hostname.example.com) or (HOST=hostname.example.com)
  defp extract_host_from_description(description) when is_binary(description) do
    case Regex.run(~r/\(host=([^)]+)\)/i, description) do
      [_, host] -> String.trim(host)
      nil -> raise "Could not extract HOST from TNS description: #{description}"
    end
  end

  defp extract_host_from_description(nil) do
    raise "TNS description is nil - cannot extract hostname"
  end

  # Parse a TNS entry from tnsnames.ora content
  # TNS entries look like: alias = (DESCRIPTION=...)
  defp parse_tns_entry(content, tns_alias) do
    # Normalize content: remove comments and normalize whitespace
    normalized =
      content
      |> String.split("\n")
      |> Enum.reject(&String.starts_with?(String.trim(&1), "#"))
      |> Enum.join(" ")
      |> String.replace(~r/\s+/, " ")

    # Build regex pattern for the alias (case-insensitive)
    alias_pattern = Regex.escape(tns_alias)
    pattern = ~r/#{alias_pattern}\s*=\s*(\(DESCRIPTION.*?\)(?=\s*[a-zA-Z_]+\s*=|\s*$))/is

    case Regex.run(pattern, normalized) do
      [_, description] ->
        String.trim(description)

      nil ->
        # Try alternative pattern for entries that span multiple lines
        # Just extract everything after alias = until next alias
        alt_pattern = ~r/#{alias_pattern}\s*=\s*(\(DESCRIPTION[^=]*(?:\([^)]*\)[^=]*)*)/is

        case Regex.run(alt_pattern, normalized) do
          [_, description] ->
            # Clean up and balance parentheses
            balance_parentheses(String.trim(description))

          nil ->
            raise "TNS alias '#{tns_alias}' not found in tnsnames.ora"
        end
    end
  end

  # Ensure parentheses are balanced in TNS description.
  # Raises ArgumentError if the string has more closing than opening parentheses,
  # which indicates a malformed TNS description that should not be silently propagated.
  @spec balance_parentheses(String.t()) :: String.t()
  defp balance_parentheses(str) do
    chars = String.graphemes(str)
    count_open = Enum.count(chars, &(&1 == "("))
    count_close = Enum.count(chars, &(&1 == ")"))

    if count_close > count_open do
      raise ArgumentError,
            "unbalanced parentheses: too many ')' in TNS description. " <>
              "count_open=#{count_open}, count_close=#{count_close}, str=#{inspect(str)}"
    end

    {balanced, _depth} = balance_chars(chars, 0, [])
    balanced |> Enum.reverse() |> Enum.join()
  end

  defp balance_chars([], depth, acc) do
    # Add closing parens if needed
    closing = String.duplicate(")", depth)
    {String.graphemes(closing) ++ acc, 0}
  end

  defp balance_chars(["(" | rest], depth, acc) do
    balance_chars(rest, depth + 1, ["(" | acc])
  end

  defp balance_chars([")" | rest], depth, acc) when depth > 0 do
    balance_chars(rest, depth - 1, [")" | acc])
  end

  defp balance_chars([")" | rest], 0, acc) do
    # Skip extra closing parens (already validated above)
    balance_chars(rest, 0, acc)
  end

  defp balance_chars([char | rest], depth, acc) do
    balance_chars(rest, depth, [char | acc])
  end
end
