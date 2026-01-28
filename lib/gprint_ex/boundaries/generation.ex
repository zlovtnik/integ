defmodule GprintEx.Boundaries.Generation do
  @moduledoc """
  Document generation context — public API for generating contract documents.
  """

  alias GprintEx.Boundaries.Contracts
  alias GprintEx.Result

  @type tenant_context :: %{tenant_id: String.t(), user: String.t()}

  @type document :: %{
          id: String.t(),
          contract_id: pos_integer(),
          filename: String.t(),
          content_type: String.t(),
          size_bytes: non_neg_integer(),
          generated_at: DateTime.t()
        }

  @doc "Generate a contract document"
  @spec generate_contract_document(tenant_context(), pos_integer(), String.t()) ::
          Result.t(document())
  def generate_contract_document(ctx, contract_id, template) do
    with {:ok, contract} <- Contracts.get_by_id(ctx, contract_id),
         {:ok, _items} <- Contracts.list_items(ctx, contract_id) do
      # TODO: Implement actual document generation
      # This would integrate with a templating engine

      document_id = generate_document_id()

      {:ok,
       %{
         id: document_id,
         contract_id: contract.id,
         filename: "contract_#{contract.contract_number}_#{template}.pdf",
         content_type: "application/pdf",
         size_bytes: 0,
         generated_at: DateTime.utc_now()
       }}
    end
  end

  @doc "Get a generated document"
  @spec get_document(tenant_context(), pos_integer(), String.t()) ::
          Result.t({document(), binary()})
  def get_document(ctx, contract_id, document_id) do
    with {:ok, _contract} <- Contracts.get_by_id(ctx, contract_id) do
      # TODO: Implement actual document retrieval from storage
      # This would integrate with S3 or similar storage

      document = %{
        id: document_id,
        contract_id: contract_id,
        filename: "contract_#{contract_id}.pdf",
        content_type: "application/pdf",
        size_bytes: 0,
        generated_at: DateTime.utc_now()
      }

      # Placeholder content
      content = "PDF content placeholder"

      {:ok, {document, content}}
    end
  end

  defp generate_document_id do
    :crypto.strong_rand_bytes(16) |> Base.url_encode64(padding: false)
  end
end
