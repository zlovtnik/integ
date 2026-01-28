defmodule GprintExWeb.ServiceController do
  @moduledoc """
  Service catalog API controller.
  """

  use Phoenix.Controller

  alias GprintEx.Boundaries.Services
  alias GprintEx.Domain.Service
  alias GprintExWeb.Plugs.AuthPlug

  action_fallback GprintExWeb.FallbackController

  def index(conn, params) do
    ctx = AuthPlug.tenant_context(conn)

    opts =
      []
      |> maybe_add(:page, params["page"], &parse_int/1)
      |> maybe_add(:page_size, params["page_size"], &parse_int/1)
      |> maybe_add(:search, params["search"])
      |> maybe_add(:active, params["active"], &parse_bool/1)
      |> maybe_add(:service_type, params["service_type"], &parse_atom/1)

    with {:ok, {services, pagination}} <- Services.list(ctx, opts) do
      conn
      |> put_status(:ok)
      |> json(%{
        success: true,
        data: Enum.map(services, &Service.to_response/1),
        pagination: pagination
      })
    end
  end

  def show(conn, %{"id" => id}) do
    ctx = AuthPlug.tenant_context(conn)

    case safe_parse_int(id) do
      {:error, :invalid_id} ->
        conn
        |> put_status(:bad_request)
        |> json(%{success: false, error: %{code: "INVALID_ID", message: "Invalid service ID"}})

      {:ok, parsed_id} ->
        with {:ok, service} <- Services.get_by_id(ctx, parsed_id) do
          conn
          |> put_status(:ok)
          |> json(%{
            success: true,
            data: Service.to_response(service)
          })
        end
    end
  end

  def create(conn, %{"service" => service_params}) do
    ctx = AuthPlug.tenant_context(conn)

    with {:ok, service} <- Services.create(ctx, service_params) do
      conn
      |> put_status(:created)
      |> json(%{
        success: true,
        data: Service.to_response(service)
      })
    end
  end

  def create(conn, params) do
    create(conn, %{"service" => params})
  end

  def update(conn, %{"id" => id, "service" => service_params}) do
    ctx = AuthPlug.tenant_context(conn)

    case safe_parse_int(id) do
      {:error, :invalid_id} ->
        conn
        |> put_status(:bad_request)
        |> json(%{success: false, error: %{code: "INVALID_ID", message: "Invalid service ID"}})

      {:ok, parsed_id} ->
        with {:ok, service} <- Services.update(ctx, parsed_id, service_params) do
          conn
          |> put_status(:ok)
          |> json(%{
            success: true,
            data: Service.to_response(service)
          })
        end
    end
  end

  def update(conn, %{"id" => id} = params) do
    service_params = Map.drop(params, ["id"])
    update(conn, %{"id" => id, "service" => service_params})
  end

  def delete(conn, %{"id" => id}) do
    ctx = AuthPlug.tenant_context(conn)

    case safe_parse_int(id) do
      {:error, :invalid_id} ->
        conn
        |> put_status(:bad_request)
        |> json(%{success: false, error: %{code: "INVALID_ID", message: "Invalid service ID"}})

      {:ok, parsed_id} ->
        with :ok <- Services.delete(ctx, parsed_id) do
          conn
          |> put_status(:no_content)
          |> send_resp(:no_content, "")
        end
    end
  end

  # Helpers

  defp maybe_add(opts, _key, nil, _parser), do: opts
  defp maybe_add(opts, _key, "", _parser), do: opts
  defp maybe_add(opts, key, value, parser), do: Keyword.put(opts, key, parser.(value))

  defp maybe_add(opts, _key, nil), do: opts
  defp maybe_add(opts, _key, ""), do: opts
  defp maybe_add(opts, key, value), do: Keyword.put(opts, key, value)

  @allowed_service_types ~w(recurring one_time usage_based)

  # parse_int used for optional filter params (returns nil on invalid)
  defp parse_int(nil), do: nil
  defp parse_int(val) when is_integer(val), do: val

  defp parse_int(val) when is_binary(val) do
    case Integer.parse(val) do
      {int, ""} -> int
      _ -> nil
    end
  end

  # safe_parse_int used for required ID params (returns error on invalid)
  defp safe_parse_int(val) when is_integer(val), do: {:ok, val}

  defp safe_parse_int(val) when is_binary(val) do
    case Integer.parse(val) do
      {int, ""} -> {:ok, int}
      _ -> {:error, :invalid_id}
    end
  end

  defp safe_parse_int(_), do: {:error, :invalid_id}

  defp parse_bool("true"), do: true
  defp parse_bool("false"), do: false
  defp parse_bool(val) when is_boolean(val), do: val
  defp parse_bool(_), do: nil

  defp parse_atom(val) when is_binary(val) do
    downcased = String.downcase(val)

    if downcased in @allowed_service_types do
      String.to_existing_atom(downcased)
    else
      nil
    end
  rescue
    ArgumentError -> nil
  end

  defp parse_atom(val) when is_atom(val), do: val
  defp parse_atom(_), do: nil
end
