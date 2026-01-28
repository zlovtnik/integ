Application.ensure_all_started(:logger)
Application.ensure_all_started(:ssl)
Application.ensure_all_started(:db_connection)

wallet = System.get_env("ORACLE_WALLET_PATH") || "/Users/rcs/git/fire/gprint/wallet"
tns = System.get_env("ORACLE_TNS_ALIAS") || "mainerc_medium"
user = System.get_env("ORACLE_USER") || "RCS"
pass = System.get_env("ORACLE_PASSWORD")

if is_nil(pass) do
  IO.puts("ERROR: ORACLE_PASSWORD not set")
  System.halt(1)
end

System.put_env("TNS_ADMIN", wallet)

IO.puts("Testing raw Jamdb.Oracle with DBConnection pool...")

# Hardcode the description to avoid parsing issues
description = "(DESCRIPTION=(CONNECT_TIMEOUT=120)(RETRY_COUNT=3)(ADDRESS=(PROTOCOL=TCPS)(PORT=1522)(HOST=adb.us-chicago-1.oraclecloud.com))(CONNECT_DATA=(SERVICE_NAME=g0ea86c98d44268_mainerc_medium.adb.oraclecloud.com)))"

opts = [
  hostname: "adb",
  database: tns,
  username: user,
  password: pass,
  description: description,
  timeout: 60_000,
  pool_size: 1,
  ssl: [cacertfile: Path.join(wallet, "cwallet.sso")]
]

IO.puts("Starting pool...")

case DBConnection.start_link(Jamdb.Oracle, opts) do
  {:ok, pid} ->
    ref = Process.monitor(pid)
    IO.puts("Pool started: #{inspect pid}, monitoring...")

    # Check every second
    Enum.each(1..15, fn i ->
      Process.sleep(1000)
      if Process.alive?(pid) do
        IO.puts("#{i}s: Pool alive")
      else
        IO.puts("#{i}s: Pool DEAD!")
      end
    end)

    # Try a query
    IO.puts("Attempting query...")
    query = %Jamdb.Oracle.Query{statement: "SELECT 1 FROM DUAL", name: "", batch: false}
    case DBConnection.prepare_execute(pid, query, [], timeout: 30_000) do
      {:ok, _, result} ->
        IO.puts("Query result: #{inspect result}")
      {:error, e} ->
        IO.puts("Query error: #{inspect e}")
    end

  {:error, e} ->
    IO.puts("Error starting pool: #{inspect e}")
end
