defmodule GprintExWeb.ContractController do
  @moduledoc """
  Contract API controller.
  """

  use Phoenix.Controller

  alias GprintEx.Boundaries.Contracts
  alias GprintEx.Domain.Contract
  alias GprintExWeb.Plugs.AuthPlug

  action_fallback GprintExWeb.FallbackController

  @allowed_statuses ~w(draft pending active suspended cancelled completed)

  # Private helper for consistent invalid ID responses
  defp invalid_id_response(conn) do
    conn
    |> put_status(:bad_request)
    |> json(%{success: false, error: %{code: "INVALID_ID", message: "Invalid contract ID"}})
  end

  def index(conn, params) do
    ctx = AuthPlug.tenant_context(conn)

    opts =
      []
      |> maybe_add(:page, params["page"], &parse_int/1)
      |> maybe_add(:page_size, params["page_size"], &parse_int/1)
      |> maybe_add(:search, params["search"])
      |> maybe_add(:status, params["status"], &parse_atom/1)
      |> maybe_add(:customer_id, params["customer_id"], &parse_int/1)
      |> maybe_add(:expiring_within_days, params["expiring_within_days"], &parse_int/1)

    with {:ok, {contracts, pagination}} <- Contracts.list(ctx, opts) do
      conn
      |> put_status(:ok)
      |> json(%{
        success: true,
        data: Enum.map(contracts, &Contract.to_response/1),
        pagination: pagination
      })
    end
  end

  def show(conn, %{"id" => id}) do
    ctx = AuthPlug.tenant_context(conn)

    case parse_int(id) do
      nil -> invalid_id_response(conn)
      {:error, :invalid_id} -> invalid_id_response(conn)
      parsed_id ->
        with {:ok, contract} <- Contracts.get_by_id(ctx, parsed_id) do
          conn
          |> put_status(:ok)
          |> json(%{
            success: true,
            data: Contract.to_response(contract)
          })
        end
    end
  end

  def create(conn, %{"contract" => contract_params}) do
    ctx = AuthPlug.tenant_context(conn)

    with {:ok, contract} <- Contracts.create(ctx, contract_params) do
      conn
      |> put_status(:created)
      |> json(%{
        success: true,
        data: Contract.to_response(contract)
      })
    end
  end

  def create(conn, params) do
    create(conn, %{"contract" => params})
  end

  def update(conn, %{"id" => id, "contract" => contract_params}) do
    ctx = AuthPlug.tenant_context(conn)

    case parse_int(id) do
      nil -> invalid_id_response(conn)
      {:error, :invalid_id} -> invalid_id_response(conn)
      parsed_id ->
        with {:ok, contract} <- Contracts.update(ctx, parsed_id, contract_params) do
          conn
          |> put_status(:ok)
          |> json(%{
            success: true,
            data: Contract.to_response(contract)
          })
        end
    end
  end

  def update(conn, %{"id" => id} = params) do
    contract_params = Map.drop(params, ["id"])
    update(conn, %{"id" => id, "contract" => contract_params})
  end

  def delete(conn, %{"id" => id}) do
    ctx = AuthPlug.tenant_context(conn)

    case parse_int(id) do
      nil -> invalid_id_response(conn)
      {:error, :invalid_id} -> invalid_id_response(conn)
      parsed_id ->
        with :ok <- Contracts.delete(ctx, parsed_id) do
          send_resp(conn, :no_content, "")
        end
    end
  end

  def transition(conn, %{"contract_id" => contract_id, "status" => new_status}) do
    ctx = AuthPlug.tenant_context(conn)

    case parse_int(contract_id) do
      nil -> invalid_id_response(conn)
      {:error, :invalid_id} -> invalid_id_response(conn)
      parsed_id ->
        case parse_atom(new_status) do
          nil ->
            conn
            |> put_status(:bad_request)
            |> json(%{
              success: false,
              error: %{
                code: "INVALID_STATUS",
                message: "Invalid status. Allowed: #{Enum.join(@allowed_statuses, ", ")}"
              }
            })

          status_atom ->
            with {:ok, contract} <- Contracts.transition_status(ctx, parsed_id, status_atom) do
              conn
              |> put_status(:ok)
              |> json(%{
                success: true,
                data: Contract.to_response(contract)
              })
            end
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

  defp parse_int(nil), do: nil
  defp parse_int(val) when is_integer(val), do: val

  defp parse_int(val) when is_binary(val) do
    case Integer.parse(val) do
      {int, ""} -> int
      _ -> {:error, :invalid_id}
    end
  end

  defp parse_atom(val) when is_binary(val) do
    downcased = String.downcase(val)

    if downcased in @allowed_statuses do
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
