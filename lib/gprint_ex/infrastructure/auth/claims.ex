defmodule GprintEx.Infrastructure.Auth.Claims do
  @moduledoc """
  JWT claims struct for type safety and documentation.
  """

  @type t :: %__MODULE__{
          user: String.t(),
          tenant_id: String.t(),
          login_session: String.t(),
          exp: pos_integer(),
          iat: pos_integer(),
          roles: [String.t()],
          permissions: [String.t()]
        }

  defstruct [
    :user,
    :tenant_id,
    :login_session,
    :exp,
    :iat,
    roles: [],
    permissions: []
  ]

  @doc "Create claims from validated JWT payload"
  @spec from_map(map()) :: t()
  def from_map(claims) when is_map(claims) do
    %__MODULE__{
      user: claims[:user] || claims["user"],
      tenant_id: claims[:tenant_id] || claims["tenant_id"],
      login_session: claims[:login_session] || claims["login_session"],
      exp: claims[:exp] || claims["exp"],
      iat: claims[:iat] || claims["iat"],
      roles: claims[:roles] || claims["roles"] || [],
      permissions: claims[:permissions] || claims["permissions"] || []
    }
  end

  @doc "Check if claims have a specific role"
  @spec has_role?(t(), String.t()) :: boolean()
  def has_role?(%__MODULE__{roles: roles}, role) do
    role in roles
  end

  @doc "Check if claims have a specific permission"
  @spec has_permission?(t(), String.t()) :: boolean()
  def has_permission?(%__MODULE__{permissions: permissions}, permission) do
    permission in permissions
  end

  @doc """
  Check if token is expired.

  Note: from_map/1 may produce a struct with exp: nil if the claim was missing.
  When exp is nil, we treat the token as expired for safety.
  """
  @spec expired?(t()) :: boolean()
  def expired?(%__MODULE__{exp: nil}), do: true

  def expired?(%__MODULE__{exp: exp}) when is_integer(exp) do
    now = System.system_time(:second)
    exp <= now
  end

  def expired?(_), do: true

  @doc "Get time until expiry in seconds (0 if already expired or exp is nil)"
  @spec time_until_expiry(t()) :: integer()
  def time_until_expiry(%__MODULE__{exp: nil}), do: 0

  def time_until_expiry(%__MODULE__{exp: exp}) when is_integer(exp) do
    now = System.system_time(:second)
    exp - now
  end

  def time_until_expiry(_), do: 0
end
