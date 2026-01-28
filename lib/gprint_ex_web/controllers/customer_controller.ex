defmodule GprintExWeb.CustomerController do
  @moduledoc """
  Customer API controller.
  """

  use Phoenix.Controller

  alias GprintEx.Boundaries.Customers
  alias GprintEx.Domain.Customer
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
      |> maybe_add(:customer_type, params["customer_type"], &parse_atom/1)

    with {:ok, {customers, pagination}} <- Customers.list(ctx, opts) do
      conn
      |> put_status(:ok)
      |> json(%{
        success: true,
        data: Enum.map(customers, &Customer.to_response/1),
        pagination: pagination
      })
    end
  end

  def show(conn, %{"id" => id}) do
    ctx = AuthPlug.tenant_context(conn)

    case parse_int(id) do
      nil ->
        conn
        |> put_status(:bad_request)
        |> json(%{success: false, error: "Invalid customer ID"})

      int_id ->
        with {:ok, customer} <- Customers.get_by_id(ctx, int_id) do
          conn
          |> put_status(:ok)
          |> json(%{
            success: true,
            data: Customer.to_response(customer)
          })
        end
    end
  end

  def create(conn, %{"customer" => customer_params}) do
    ctx = AuthPlug.tenant_context(conn)

    with {:ok, customer} <- Customers.create(ctx, customer_params) do
      conn
      |> put_status(:created)
      |> json(%{
        success: true,
        data: Customer.to_response(customer)
      })
    end
  end

  def create(conn, params) do
    create(conn, %{"customer" => params})
  end

  def update(conn, %{"id" => id, "customer" => customer_params}) do
    ctx = AuthPlug.tenant_context(conn)

    case parse_int(id) do
      nil ->
        conn
        |> put_status(:bad_request)
        |> json(%{success: false, error: "Invalid customer ID"})

      int_id ->
        with {:ok, customer} <- Customers.update(ctx, int_id, customer_params) do
          conn
          |> put_status(:ok)
          |> json(%{
            success: true,
            data: Customer.to_response(customer)
          })
        end
    end
  end

  def update(conn, %{"id" => id} = params) do
    customer_params = Map.drop(params, ["id"])
    update(conn, %{"id" => id, "customer" => customer_params})
  end

  def delete(conn, %{"id" => id}) do
    ctx = AuthPlug.tenant_context(conn)

    case parse_int(id) do
      nil ->
        conn
        |> put_status(:bad_request)
        |> json(%{success: false, error: "Invalid customer ID"})

      int_id ->
        with :ok <- Customers.delete(ctx, int_id) do
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

  @allowed_customer_types ~w(individual company)

  defp parse_int(nil), do: nil
  defp parse_int(val) when is_integer(val), do: val

  defp parse_int(val) when is_binary(val) do
    case Integer.parse(val) do
      {int, ""} -> int
      _ -> nil
    end
  end

  defp parse_bool("true"), do: true
  defp parse_bool("false"), do: false
  defp parse_bool(val) when is_boolean(val), do: val
  defp parse_bool(_), do: nil

  defp parse_atom(val) when is_binary(val) do
    downcased = String.downcase(val)

    if downcased in @allowed_customer_types do
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
