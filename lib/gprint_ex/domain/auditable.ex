defprotocol GprintEx.Domain.Auditable do
  @moduledoc "Protocol for entities that can be audited"

  @doc "Get entity type for audit trail"
  @spec entity_type(t) :: String.t()
  def entity_type(entity)

  @doc "Get entity ID"
  @spec entity_id(t) :: String.t() | pos_integer()
  def entity_id(entity)

  @doc "Convert to audit snapshot"
  @spec to_audit_snapshot(t) :: map()
  def to_audit_snapshot(entity)
end
