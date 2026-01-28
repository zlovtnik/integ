defmodule GprintEx.ETL.Extractors.FileExtractor do
  @moduledoc """
  ETL Extractor for file-based data sources.

  Supports CSV, JSON, and other delimited file formats.
  Handles encoding detection, streaming for large files,
  and basic validation of input data.

  ## Example

      opts = [file: "contracts.csv", format: :csv, encoding: :utf8]
      {:ok, data} = FileExtractor.extract(opts, context)
  """

  require Logger

  alias GprintEx.Integration.Translators.FormatTranslator

  @behaviour GprintEx.ETL.Extractor

  @type format :: :csv | :json | :jsonl | :tsv | :xml

  @impl true
  @spec extract(keyword(), map()) :: {:ok, [map()]} | {:error, term()}
  def extract(opts, _context) do
    file_path = Keyword.fetch!(opts, :file)
    format = Keyword.get(opts, :format, detect_format(file_path))
    encoding = Keyword.get(opts, :encoding, :utf8)

    Logger.debug("Extracting from file: #{file_path}, format: #{format}")

    with {:ok, content} <- read_file(file_path, encoding),
         {:ok, data} <- parse_content(content, format, opts) do
      Logger.info("Extracted #{length(data)} records from #{file_path}")
      {:ok, data}
    end
  end

  @doc """
  Extract data from a file stream for large files.
  """
  @spec extract_stream(keyword(), map()) :: {:ok, Enumerable.t()} | {:error, term()}
  def extract_stream(opts, _context) do
    file_path = Keyword.fetch!(opts, :file)
    format = Keyword.get(opts, :format, detect_format(file_path))
    chunk_size = Keyword.get(opts, :chunk_size, 1000)
    encoding = Keyword.get(opts, :encoding, :utf8)

    stream =
      if encoding in [:utf8, :latin1] do
        file_path
        |> File.stream!([], :line)
        |> apply_encoding(encoding)
      else
        # For multi-byte encodings, read in binary chunks with proper boundary handling
        file_path
        |> File.stream!([:binary, :read_ahead], 4096)
        |> Stream.transform("", fn chunk, leftover ->
          input = leftover <> chunk
          case :unicode.characters_to_binary(input, encoding) do
            binary when is_binary(binary) ->
              # Split on newlines, keeping last partial line for next chunk
              lines = String.split(binary, "\n", trim: false)
              case lines do
                [] -> {[], ""}
                [single] -> {[], single}
                _ ->
                  {complete, [partial]} = Enum.split(lines, -1)
                  {complete, partial}
              end
            {:incomplete, converted, rest} ->
              lines = String.split(converted, "\n", trim: false)
              case lines do
                [] -> {[], rest}
                [single] -> {[], single <> rest}
                _ ->
                  {complete, [partial]} = Enum.split(lines, -1)
                  {complete, partial <> rest}
              end
            {:error, _, _} ->
              Logger.error("Failed to decode chunk with encoding #{encoding}")
              {[], leftover}
          end
        end)
      end
      |> stream_parser(format, opts)
      |> Stream.chunk_every(chunk_size)

    {:ok, stream}
  end

  # Apply encoding conversion to stream lines
  defp apply_encoding(stream, :utf8), do: stream
  defp apply_encoding(stream, encoding) do
    Stream.map(stream, fn line ->
      case :unicode.characters_to_binary(line, encoding) do
        binary when is_binary(binary) -> binary
        {:error, _, _} -> line
        {:incomplete, _, _} -> line
      end
    end)
  end

  @doc """
  Detect file format from extension.
  """
  @spec detect_format(String.t()) :: format()
  def detect_format(file_path) do
    case Path.extname(file_path) |> String.downcase() do
      ".csv" -> :csv
      ".json" -> :json
      ".jsonl" -> :jsonl
      ".ndjson" -> :jsonl
      ".tsv" -> :tsv
      ".xml" -> :xml
      _ -> :csv
    end
  end

  # Private functions

  defp read_file(path, encoding) do
    case File.read(path) do
      {:ok, content} ->
        decode_content(content, encoding)

      {:error, reason} ->
        Logger.error("Failed to read file #{path}: #{inspect(reason)}")
        {:error, {:file_read_error, reason}}
    end
  end

  defp decode_content(content, :utf8), do: {:ok, content}

  defp decode_content(content, :latin1) do
    case :unicode.characters_to_binary(content, :latin1) do
      binary when is_binary(binary) -> {:ok, binary}
      {:error, _, _} = err -> {:error, {:invalid_encoding, :latin1, err}}
      {:incomplete, _, _} = err -> {:error, {:invalid_encoding, :latin1, err}}
    end
  end

  defp decode_content(content, :utf16) do
    case :unicode.characters_to_binary(content, :utf16) do
      binary when is_binary(binary) -> {:ok, binary}
      {:error, _, _} = err -> {:error, {:invalid_encoding, :utf16, err}}
      {:incomplete, _, _} = err -> {:error, {:invalid_encoding, :utf16, err}}
    end
  end

  defp decode_content(content, _), do: {:ok, content}

  defp parse_content(content, :csv, opts) do
    delimiter = Keyword.get(opts, :delimiter, ",")
    headers = Keyword.get(opts, :headers, true)

    FormatTranslator.parse_delimited(content, delimiter: delimiter, headers: headers)
  end

  defp parse_content(content, :tsv, opts) do
    opts = Keyword.put(opts, :delimiter, "\t")
    parse_content(content, :csv, opts)
  end

  defp parse_content(content, :json, _opts) do
    case Jason.decode(content) do
      {:ok, data} when is_list(data) -> {:ok, data}
      {:ok, data} when is_map(data) -> {:ok, [data]}
      {:error, error} -> {:error, {:json_parse_error, error}}
    end
  end

  defp parse_content(content, :jsonl, _opts) do
    lines =
      content
      |> String.split(~r/\r?\n/)
      |> Enum.map(&String.trim_trailing(&1, "\r"))
      |> Enum.reject(&(&1 == ""))
      |> Enum.with_index()

    parse_jsonl_lines(lines, [])
  end

  defp parse_content(content, :xml, _opts) do
    FormatTranslator.convert(content, :xml, :map)
    |> case do
      {:ok, data} when is_list(data) -> {:ok, data}
      {:ok, data} when is_map(data) -> {:ok, [data]}
      error -> error
    end
  end

  defp parse_jsonl_lines([], acc), do: {:ok, Enum.reverse(acc)}

  defp parse_jsonl_lines([{line, index} | rest], acc) do
    case Jason.decode(line) do
      {:ok, decoded} ->
        parse_jsonl_lines(rest, [decoded | acc])
      {:error, reason} ->
        {:error, {:jsonl_parse_error, index, reason}}
    end
  end

  defp stream_parser(stream, :csv, opts) do
    delimiter = Keyword.get(opts, :delimiter, ",")
    skip_header = Keyword.get(opts, :skip_header, true)
    headers_opt = Keyword.get(opts, :header_names)

    stream
    |> Stream.transform(nil, fn
      line, nil when skip_header ->
        # First line is header - parse and skip
        headers = parse_csv_line(String.trim(line), delimiter)
        {[], headers_opt || headers}

      line, nil ->
        # First line when not skipping header - use provided headers or parse first line as headers
        headers = headers_opt || parse_csv_line(String.trim(line), delimiter)
        if headers_opt do
          # Headers provided, first line is data
          values = parse_csv_line(String.trim(line), delimiter)
          record = Enum.zip(headers, values) |> Map.new()
          {[record], headers}
        else
          # No headers provided, first line becomes headers
          {[], headers}
        end

      line, headers ->
        values = parse_csv_line(String.trim(line), delimiter)
        record = Enum.zip(headers, values) |> Map.new()
        {[record], headers}
    end)
  end

  defp stream_parser(stream, :jsonl, _opts) do
    Stream.flat_map(stream, fn line ->
      trimmed = String.trim(line)
      if trimmed == "" do
        []
      else
        case Jason.decode(trimmed) do
          {:ok, decoded} -> [decoded]
          {:error, reason} ->
            Logger.warning("Skipping malformed JSONL line: #{inspect(reason)}")
            []
        end
      end
    end)
  end

  defp stream_parser(stream, _format, opts) do
    stream_parser(stream, :csv, opts)
  end

  # Parse a CSV line respecting quoted fields
  defp parse_csv_line(line, delimiter) do
    parse_csv_fields(line, delimiter, [], "", false)
  end

  defp parse_csv_fields("", _delimiter, fields, current, _in_quotes) do
    Enum.reverse([current | fields])
  end

  defp parse_csv_fields(<<"\"\"", rest::binary>>, delimiter, fields, current, true) do
    # Escaped quote inside quoted field
    parse_csv_fields(rest, delimiter, fields, current <> "\"", true)
  end

  defp parse_csv_fields(<<"\"", rest::binary>>, delimiter, fields, current, false) do
    # Start of quoted field
    parse_csv_fields(rest, delimiter, fields, current, true)
  end

  defp parse_csv_fields(<<"\"", rest::binary>>, delimiter, fields, current, true) do
    # End of quoted field
    parse_csv_fields(rest, delimiter, fields, current, false)
  end

  defp parse_csv_fields(binary, delimiter, fields, current, false) when binary_part(binary, 0, byte_size(delimiter)) == delimiter do
    # Delimiter outside quotes
    <<_del::binary-size(byte_size(delimiter)), rest::binary>> = binary
    parse_csv_fields(rest, delimiter, [current | fields], "", false)
  end

  defp parse_csv_fields(<<char, rest::binary>>, delimiter, fields, current, in_quotes) do
    parse_csv_fields(rest, delimiter, fields, current <> <<char>>, in_quotes)
  end
end
