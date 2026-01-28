defmodule GprintEx.Integration.Translators.FormatTranslator do
  @moduledoc """
  Generic format translator for message payloads.

  Handles conversion between common data formats (JSON, XML, CSV)
  and provides utilities for format detection and validation.

  ## Example

      # Convert JSON to XML
      {:ok, xml} = FormatTranslator.convert(json_string, :json, :xml)

      # Detect format
      {:ok, :json} = FormatTranslator.detect_format(data)
  """

  @type format :: :json | :xml | :csv | :binary | :map

  @doc """
  Convert data from one format to another.
  """
  @spec convert(term(), format(), format()) :: {:ok, term()} | {:error, term()}
  def convert(data, from_format, to_format)

  def convert(data, format, format), do: {:ok, data}

  def convert(data, :json, :map) when is_binary(data) do
    Jason.decode(data)
  end

  def convert(data, :map, :json) when is_map(data) do
    Jason.encode(data)
  end

  def convert(data, :json, :xml) when is_binary(data) do
    with {:ok, map} <- Jason.decode(data) do
      convert(map, :map, :xml)
    end
  end

  def convert(data, :map, :xml) when is_map(data) do
    xml = map_to_xml(data, "root")
    {:ok, xml}
  end

  def convert(data, :xml, :map) when is_binary(data) do
    # Simple XML to map conversion
    # For production, use a proper XML parser like SweetXml
    case parse_simple_xml(data) do
      {:ok, map} -> {:ok, map}
      {:error, _} = error -> error
    end
  end

  def convert(data, :xml, :json) when is_binary(data) do
    with {:ok, map} <- convert(data, :xml, :map),
         {:ok, json} <- Jason.encode(map) do
      {:ok, json}
    end
  end

  def convert(data, :csv, :map) when is_binary(data) do
    case parse_csv(data) do
      {:ok, rows} -> {:ok, rows}
      {:error, _} = error -> error
    end
  end

  def convert(data, :map, :csv) when is_list(data) do
    csv = maps_to_csv(data)
    {:ok, csv}
  end

  @doc """
  Detect the format of input data.
  """
  @spec detect_format(term()) :: {:ok, format()} | {:error, :unknown_format}
  def detect_format(data) when is_map(data), do: {:ok, :map}
  def detect_format(data) when is_binary(data), do: detect_string_format(data)
  def detect_format(_), do: {:error, :unknown_format}

  @doc """
  Validate that data is in the expected format.
  """
  @spec validate_format(term(), format()) :: :ok | {:error, :invalid_format}
  def validate_format(data, :json) when is_binary(data) do
    case Jason.decode(data) do
      {:ok, _} -> :ok
      {:error, _} -> {:error, :invalid_format}
    end
  end

  def validate_format(data, :map) when is_map(data), do: :ok

  def validate_format(data, :xml) when is_binary(data) do
    trimmed = String.trim(data)

    if String.starts_with?(trimmed, "<") do
      # Attempt real XML parsing for well-formedness check
      try do
        case :xmerl_scan.string(String.to_charlist(trimmed), []) do
          {_element, _rest} -> :ok
          _ -> {:error, :invalid_format}
        end
      catch
        :exit, _ -> {:error, :invalid_format}
      end
    else
      {:error, :invalid_format}
    end
  end

  def validate_format(_, _), do: {:error, :invalid_format}

  @doc """
  Parse JSON with error handling.
  """
  @spec parse_json(String.t()) :: {:ok, map()} | {:error, term()}
  def parse_json(json) when is_binary(json) do
    Jason.decode(json)
  end

  @doc """
  Encode to JSON with error handling.
  """
  @spec encode_json(term()) :: {:ok, String.t()} | {:error, term()}
  def encode_json(data) do
    Jason.encode(data)
  end

  @doc """
  Pretty-print JSON.
  """
  @spec encode_json_pretty(term()) :: {:ok, String.t()} | {:error, term()}
  def encode_json_pretty(data) do
    Jason.encode(data, pretty: true)
  end

  @doc """
  Parse a delimited string (CSV, TSV, etc).
  """
  @spec parse_delimited(String.t(), keyword()) :: {:ok, [map()]} | {:error, term()}
  def parse_delimited(data, opts \\ []) do
    delimiter = Keyword.get(opts, :delimiter, ",")
    has_headers = Keyword.get(opts, :headers, true)

    lines =
      data
      |> String.trim()
      |> String.split(~r/\r?\n/)
      |> Enum.map(&parse_csv_line(&1, delimiter))

    case lines do
      [] ->
        {:ok, []}

      [headers | rows] when has_headers ->
        headers = Enum.map(headers, &String.trim/1)

        maps =
          Enum.map(rows, fn row ->
            row
            |> Enum.map(&String.trim/1)
            |> Enum.zip(headers)
            |> Enum.map(fn {v, k} -> {k, v} end)
            |> Map.new()
          end)

        {:ok, maps}

      rows ->
        {:ok, rows}
    end
  end

  # Parse a single CSV line handling quoted fields
  defp parse_csv_line(line, delimiter) do
    do_parse_csv_line(line, delimiter, [], "", false)
  end

  defp do_parse_csv_line("", _delimiter, fields, current, _in_quotes) do
    Enum.reverse([current | fields])
  end

  defp do_parse_csv_line(<<"\"", rest::binary>>, delimiter, fields, current, false) do
    # Start of quoted field
    do_parse_csv_line(rest, delimiter, fields, current, true)
  end

  defp do_parse_csv_line(<<"\"\"", rest::binary>>, delimiter, fields, current, true) do
    # Escaped quote within quoted field
    do_parse_csv_line(rest, delimiter, fields, current <> "\"", true)
  end

  defp do_parse_csv_line(<<"\"", rest::binary>>, delimiter, fields, current, true) do
    # End of quoted field
    do_parse_csv_line(rest, delimiter, fields, current, false)
  end

  defp do_parse_csv_line(<<char, rest::binary>>, delimiter, fields, current, in_quotes)
       when in_quotes do
    # Inside quoted field, just accumulate
    do_parse_csv_line(rest, delimiter, fields, current <> <<char>>, true)
  end

  defp do_parse_csv_line(<<char, rest::binary>>, delimiter, fields, current, false) do
    if <<char>> == delimiter do
      # End of field
      do_parse_csv_line(rest, delimiter, [current | fields], "", false)
    else
      do_parse_csv_line(rest, delimiter, fields, current <> <<char>>, false)
    end
  end

  @doc """
  Flatten a nested map to dot-notation keys.
  """
  @spec flatten_map(map(), String.t()) :: map()
  def flatten_map(map, prefix \\ "") do
    Enum.reduce(map, %{}, fn {key, value}, acc ->
      full_key = if prefix == "", do: to_string(key), else: "#{prefix}.#{key}"

      case value do
        nested when is_map(nested) and map_size(nested) > 0 ->
          Map.merge(acc, flatten_map(nested, full_key))

        _ ->
          Map.put(acc, full_key, value)
      end
    end)
  end

  @doc """
  Expand dot-notation keys to nested map.
  """
  @spec expand_map(map()) :: map()
  def expand_map(flat_map) do
    Enum.reduce(flat_map, %{}, fn {key, value}, acc ->
      key_parts = String.split(to_string(key), ".")
      put_nested(acc, key_parts, value)
    end)
  end

  # Private functions

  defp detect_string_format(data) do
    trimmed = String.trim(data)

    cond do
      String.starts_with?(trimmed, "{") or String.starts_with?(trimmed, "[") ->
        case Jason.decode(data) do
          {:ok, _} -> {:ok, :json}
          _ -> {:error, :unknown_format}
        end

      String.starts_with?(trimmed, "<") ->
        {:ok, :xml}

      String.contains?(trimmed, ",") and
          (String.contains?(trimmed, "\n") or
             String.contains?(trimmed, "\r") or
             length(String.split(trimmed, ",")) >= 2) ->
        {:ok, :csv}

      true ->
        {:error, :unknown_format}
    end
  end

  defp map_to_xml(map, root_name) when is_map(map) do
    content =
      map
      |> Enum.map(fn {k, v} -> element_to_xml(to_string(k), v) end)
      |> Enum.join("\n")

    "<#{root_name}>\n#{content}\n</#{root_name}>"
  end

  defp element_to_xml(name, value) when is_map(value) do
    inner = map_to_xml(value, name)
    inner
  end

  defp element_to_xml(name, value) when is_list(value) do
    items =
      value
      |> Enum.map(&element_to_xml("item", &1))
      |> Enum.join("\n")

    "<#{name}>\n#{items}\n</#{name}>"
  end

  defp element_to_xml(name, value) do
    escaped = escape_xml(to_string(value))
    "  <#{name}>#{escaped}</#{name}>"
  end

  defp escape_xml(str) do
    str
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace("\"", "&quot;")
    |> String.replace("'", "&apos;")
  end

  defp parse_simple_xml(xml) do
    # Very simple XML parsing - for production use SweetXml or similar
    # This handles basic cases only
    try do
      # Remove XML declaration if present
      cleaned = Regex.replace(~r/<\?xml[^?]*\?>/, xml, "")

      # Extract root element content
      case Regex.run(~r/<(\w+)[^>]*>(.*)<\/\1>/s, cleaned) do
        [_, _root, content] ->
          map = parse_xml_content(content)
          {:ok, map}

        _ ->
          {:error, :invalid_xml}
      end
    rescue
      _ -> {:error, :parse_error}
    end
  end

  defp parse_xml_content(content) do
    # Extract all elements
    Regex.scan(~r/<(\w+)[^>]*>([^<]*)<\/\1>/, content)
    |> Enum.map(fn [_, name, value] -> {name, String.trim(value)} end)
    |> Map.new()
  end

  defp parse_csv(data), do: parse_delimited(data, delimiter: ",", headers: true)

  defp maps_to_csv([]), do: ""

  defp maps_to_csv([first | _] = maps) do
    headers = Map.keys(first) |> Enum.map(&to_string/1)
    header_line = Enum.join(headers, ",")

    data_lines =
      maps
      |> Enum.map(fn map ->
        headers
        |> Enum.map(&Map.get(map, &1, Map.get(map, String.to_atom(&1), "")))
        |> Enum.map(&csv_escape/1)
        |> Enum.join(",")
      end)

    [header_line | data_lines] |> Enum.join("\n")
  end

  defp csv_escape(nil), do: ""

  defp csv_escape(value) when is_binary(value) do
    if String.contains?(value, [",", "\"", "\n"]) do
      "\"#{String.replace(value, "\"", "\"\"")}\""
    else
      value
    end
  end

  defp csv_escape(value), do: to_string(value)

  defp put_nested(map, [key], value) do
    Map.put(map, key, value)
  end

  defp put_nested(map, [key | rest], value) do
    nested = Map.get(map, key, %{})

    nested =
      if is_map(nested) do
        nested
      else
        # Parent key holds a non-map value; overwrite with a new map
        %{}
      end

    Map.put(map, key, put_nested(nested, rest, value))
  end
end
