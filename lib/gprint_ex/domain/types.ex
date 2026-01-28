defmodule GprintEx.Domain.Types do
  @moduledoc """
  Shared types and type aliases for the domain layer.
  """

  @type tenant_id :: String.t()
  @type user_id :: String.t()
  @type entity_id :: pos_integer()

  @type address :: %{
          optional(:street) => String.t(),
          optional(:number) => String.t(),
          optional(:complement) => String.t(),
          optional(:district) => String.t(),
          optional(:city) => String.t(),
          optional(:state) => String.t(),
          optional(:zip) => String.t(),
          optional(:country) => String.t()
        }

  @type money :: Decimal.t()

  @type pagination :: %{
          page: pos_integer(),
          page_size: pos_integer(),
          total: non_neg_integer(),
          total_pages: non_neg_integer()
        }

  @doc "Build address map from flat database row"
  @spec build_address(map()) :: address() | nil
  def build_address(row) when is_map(row) do
    # First build address without defaulting country
    raw_address = %{
      street: row[:address_street],
      number: row[:address_number],
      complement: row[:address_comp],
      district: row[:address_district],
      city: row[:address_city],
      state: row[:address_state],
      zip: row[:address_zip],
      country: row[:address_country]
    }

    # Return nil if all fields are nil (including country)
    if Enum.all?(Map.values(raw_address), &is_nil/1) do
      nil
    else
      # Only default country to "BR" when we have a non-nil address
      %{raw_address | country: raw_address.country || "BR"}
    end
  end

  def build_address(_), do: nil

  @doc "Calculate pagination metadata"
  @spec paginate(non_neg_integer(), pos_integer(), integer()) :: pagination()
  def paginate(total, page, page_size) when page_size > 0 do
    total_pages = max(1, ceil(total / page_size))

    %{
      page: page,
      page_size: page_size,
      total: total,
      total_pages: total_pages
    }
  end

  def paginate(total, page, _page_size) do
    # Guard against page_size <= 0 by defaulting to sensible values
    %{
      page: page,
      page_size: 20,
      total: total,
      total_pages: max(1, ceil(total / 20))
    }
  end
end
