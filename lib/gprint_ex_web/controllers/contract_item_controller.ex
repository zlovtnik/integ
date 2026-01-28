defmodule GprintExWeb.ContractItemController do
  @moduledoc """
  Contract items API controller (nested under contracts).
  """

  use Phoenix.Controller

  alias GprintEx.Boundaries.Contracts
  alias GprintEx.Domain.ContractItem
  alias GprintExWeb.Plugs.AuthPlug

  action_fallback GprintExWeb.FallbackController

  # Allowed keys for contract item params - explicit whitelist to prevent
  # forwarding unintended keys (e.g., "action", "controller") to the domain layer
  @allowed_item_keys [
    "service_id",
    "description",
    "quantity",
    "unit_price",
    "discount_pct",
    "notes"
  ]

  def index(conn, %{"contract_id" => contract_id}) do
    ctx = AuthPlug.tenant_context(conn)

    with {:ok, contract_id_int} <- parse_int(contract_id),
         {:ok, items} <- Contracts.list_items(ctx, contract_id_int) do
      conn
      |> put_status(:ok)
      |> json(%{
        success: true,
        data: Enum.map(items, &ContractItem.to_response/1)
      })
    end
  end

  def show(conn, %{"contract_id" => contract_id, "id" => id}) do
    ctx = AuthPlug.tenant_context(conn)

    with {:ok, contract_id_int} <- parse_int(contract_id),
         {:ok, id_int} <- parse_int(id),
         {:ok, item} <- Contracts.get_item(ctx, contract_id_int, id_int) do
      conn
      |> put_status(:ok)
      |> json(%{
        success: true,
        data: ContractItem.to_response(item)
      })
    end
  end

  def create(conn, %{"contract_id" => contract_id, "item" => item_params}) do
    ctx = AuthPlug.tenant_context(conn)

    with {:ok, contract_id_int} <- parse_int(contract_id),
         {:ok, item} <- Contracts.add_item(ctx, contract_id_int, item_params) do
      conn
      |> put_status(:created)
      |> json(%{
        success: true,
        data: ContractItem.to_response(item)
      })
    end
  end

  def create(conn, %{"contract_id" => contract_id} = params) do
    # Use explicit whitelist to prevent forwarding unintended keys to domain layer
    item_params = contract_item_params(params)
    create(conn, %{"contract_id" => contract_id, "item" => item_params})
  end

  def update(conn, %{"contract_id" => contract_id, "id" => id, "item" => item_params}) do
    ctx = AuthPlug.tenant_context(conn)

    with {:ok, contract_id_int} <- parse_int(contract_id),
         {:ok, id_int} <- parse_int(id),
         {:ok, item} <- Contracts.update_item(ctx, contract_id_int, id_int, item_params) do
      conn
      |> put_status(:ok)
      |> json(%{
        success: true,
        data: ContractItem.to_response(item)
      })
    end
  end

  def update(conn, %{"contract_id" => contract_id, "id" => id} = params) do
    # Use explicit whitelist to prevent forwarding unintended keys to domain layer
    item_params = contract_item_params(params)
    update(conn, %{"contract_id" => contract_id, "id" => id, "item" => item_params})
  end

  def delete(conn, %{"contract_id" => contract_id, "id" => id}) do
    ctx = AuthPlug.tenant_context(conn)

    with {:ok, contract_id_int} <- parse_int(contract_id),
         {:ok, id_int} <- parse_int(id),
         :ok <- Contracts.delete_item(ctx, contract_id_int, id_int) do
      send_resp(conn, :no_content, "")
    end
  end

  # Extracts only permitted item keys from params
  @spec contract_item_params(map()) :: map()
  defp contract_item_params(params) do
    Map.take(params, @allowed_item_keys)
  end

  # Safe integer parsing that returns {:ok, int} or {:error, :invalid_integer}
  @spec parse_int(integer() | String.t()) :: {:ok, integer()} | {:error, :bad_request}
  defp parse_int(val) when is_integer(val), do: {:ok, val}

  defp parse_int(val) when is_binary(val) do
    case Integer.parse(val) do
      {int, ""} -> {:ok, int}
      _ -> {:error, :bad_request}
    end
  end
end
