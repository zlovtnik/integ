defmodule GprintEx.Infrastructure.WalletSetup do
  @moduledoc """
  Handles Oracle wallet setup from base64-encoded zip files.

  In production/containerized environments, the wallet can be provided as a
  base64-encoded zip file via the ORACLE_WALLET_BASE64 environment variable.
  This module decodes and extracts it to a temporary directory.

  Usage:
    # In .env or environment:
    ORACLE_WALLET_BASE64=UEsDBBQAAAAI...  # base64 of wallet.zip

    # At application startup:
    {:ok, wallet_path} = WalletSetup.ensure_wallet()
  """

  require Logger

  @wallet_files ~w(cwallet.sso tnsnames.ora sqlnet.ora)

  @doc """
  Ensures an Oracle wallet is available, returning the path.

  Priority:
  1. ORACLE_WALLET_PATH - use existing directory
  2. ORACLE_WALLET_BASE64 - decode and extract zip to temp dir
  3. Default path (./priv/wallet)

  Returns {:ok, path} or {:error, reason}
  """
  @spec ensure_wallet() :: {:ok, String.t()} | {:error, term()}
  def ensure_wallet do
    cond do
      # Option 1: Direct path to wallet directory (ignore blank strings)
      path = present_env("ORACLE_WALLET_PATH") ->
        validate_wallet_path(path)

      # Option 2: Base64-encoded wallet zip (ignore blank strings)
      base64 = present_env("ORACLE_WALLET_BASE64") ->
        extract_wallet_from_base64(base64)

      # Option 3: Default development path
      true ->
        default_path = Path.expand("./priv/wallet")
        validate_wallet_path(default_path)
    end
  end

  @doc """
  Extracts a base64-encoded wallet zip to a temporary directory.
  """
  @spec extract_wallet_from_base64(String.t()) :: {:ok, String.t()} | {:error, term()}
  def extract_wallet_from_base64(base64_content) do
    with {:ok, zip_binary} <- decode_base64(base64_content),
         {:ok, extract_path} <- create_temp_wallet_dir(),
         :ok <- extract_zip(zip_binary, extract_path),
         {:ok, _} <- validate_wallet_path(extract_path) do
      Logger.info("Oracle wallet extracted to: #{extract_path}")
      {:ok, extract_path}
    end
  end

  defp present_env(var) do
    case System.get_env(var) do
      nil -> nil
      value ->
        trimmed = String.trim(value)
        if trimmed == "", do: nil, else: trimmed
    end
  end

  # Decode base64 content
  defp decode_base64(base64_content) do
    # Remove any whitespace/newlines from base64 string
    cleaned = String.replace(base64_content, ~r/\s/, "")

    case Base.decode64(cleaned) do
      {:ok, binary} ->
        {:ok, binary}

      :error ->
        Logger.error("Failed to decode ORACLE_WALLET_BASE64 - invalid base64")
        {:error, :invalid_base64}
    end
  end

  # Create a temporary directory for the wallet
  defp create_temp_wallet_dir do
    temp_base = System.tmp_dir!()
    wallet_dir = Path.join(temp_base, "oracle_wallet_#{:erlang.unique_integer([:positive])}")

    case File.mkdir_p(wallet_dir) do
      :ok ->
        {:ok, wallet_dir}

      {:error, reason} ->
        Logger.error("Failed to create wallet directory #{wallet_dir}: #{inspect(reason)}")
        {:error, {:mkdir_failed, reason}}
    end
  end

  # Extract zip binary to path
  defp extract_zip(zip_binary, extract_path) do
    # :zip.extract expects a charlist for the path
    extract_path_charlist = String.to_charlist(extract_path)

    case :zip.extract(zip_binary, [{:cwd, extract_path_charlist}]) do
      {:ok, _files} ->
        :ok

      {:error, reason} ->
        Logger.error("Failed to extract wallet zip: #{inspect(reason)}")
        {:error, {:unzip_failed, reason}}
    end
  end

  # Validate that the wallet path exists and contains required files
  defp validate_wallet_path(path) do
    cond do
      not File.dir?(path) ->
        Logger.error("Wallet path does not exist or is not a directory: #{path}")
        {:error, {:wallet_not_found, path}}

      not has_required_files?(path) ->
        missing = missing_files(path)
        Logger.error("Wallet missing required files: #{inspect(missing)} in #{path}")
        {:error, {:missing_wallet_files, missing}}

      true ->
        Logger.debug("Oracle wallet validated at: #{path}")
        {:ok, path}
    end
  end

  defp has_required_files?(path) do
    # At minimum we need cwallet.sso and tnsnames.ora
    File.exists?(Path.join(path, "cwallet.sso")) and
      File.exists?(Path.join(path, "tnsnames.ora"))
  end

  defp missing_files(path) do
    Enum.filter(@wallet_files, fn file ->
      not File.exists?(Path.join(path, file))
    end)
  end
end
