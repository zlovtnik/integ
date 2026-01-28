defmodule GprintExWeb.Plugs.RequestIdPlug do
  @moduledoc """
  Plug to ensure request ID is in conn assigns and logger metadata.
  """

  import Plug.Conn
  require Logger

  @behaviour Plug

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    request_id =
      case get_req_header(conn, "x-request-id") do
        [id | _] -> id
        [] -> generate_request_id()
      end

    Logger.metadata(request_id: request_id)

    conn
    |> assign(:request_id, request_id)
    |> put_resp_header("x-request-id", request_id)
  end

  defp generate_request_id do
    :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)
  end
end
