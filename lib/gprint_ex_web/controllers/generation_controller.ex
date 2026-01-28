defmodule GprintExWeb.GenerationController do
  @moduledoc """
  Document generation API controller.
  """

  use Phoenix.Controller

  alias GprintEx.Boundaries.Generation
  alias GprintExWeb.Plugs.AuthPlug

  action_fallback GprintExWeb.FallbackController

  def generate(conn, %{"contract_id" => contract_id} = params) do
    ctx = AuthPlug.tenant_context(conn)
    template = params["template"] || "default"

    case parse_int(contract_id) do
      {:error, :invalid_id} ->
        conn
        |> put_status(:bad_request)
        |> json(%{success: false, error: %{code: "INVALID_ID", message: "Invalid contract ID"}})

      parsed_id ->
        with {:ok, document} <-
               Generation.generate_contract_document(ctx, parsed_id, template) do
          conn
          |> put_status(:ok)
          |> json(%{
            success: true,
            data: %{
              document_id: document.id,
              filename: document.filename,
              content_type: document.content_type,
              size_bytes: document.size_bytes,
              download_url: "/api/v1/contracts/#{contract_id}/document?document_id=#{document.id}",
              generated_at: document.generated_at
            }
          })
        end
    end
  end

  def download(conn, %{"contract_id" => contract_id} = params) do
    ctx = AuthPlug.tenant_context(conn)
    document_id = params["document_id"]

    case parse_int(contract_id) do
      {:error, :invalid_id} ->
        conn
        |> put_status(:bad_request)
        |> json(%{success: false, error: %{code: "INVALID_ID", message: "Invalid contract ID"}})

      parsed_id ->
        with {:ok, {document, content}} <-
               Generation.get_document(ctx, parsed_id, document_id) do
          # Sanitize filename to prevent header injection
          safe_filename = sanitize_filename(document.filename)

          conn
          |> put_resp_content_type(document.content_type)
          |> put_resp_header("content-disposition", ~s(attachment; filename="#{safe_filename}"))
          |> send_resp(:ok, content)
        end
    end
  end

  # Sanitize filename to prevent header injection attacks
  # Removes/escapes quotes, newlines, and control characters
  defp sanitize_filename(nil), do: "document"

  defp sanitize_filename(filename) when is_binary(filename) do
    filename
    # Replace control chars and quotes
    |> String.replace(~r/["\r\n\x00-\x1f]/, "_")
    # Limit length
    |> String.slice(0, 255)
  end

  defp sanitize_filename(_), do: "document"

  defp parse_int(val) when is_integer(val), do: val

  defp parse_int(val) when is_binary(val) do
    case Integer.parse(val) do
      {int, ""} -> int
      _ -> {:error, :invalid_id}
    end
  end

  defp parse_int(_), do: {:error, :invalid_id}
end
