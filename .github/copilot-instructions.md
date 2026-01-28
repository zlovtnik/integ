# GprintEx - AI Coding Instructions

> Contract Lifecycle Management (CLM) service: Functional-first Elixir with Oracle ADB backend and Keycloak auth.

## Architecture

**Layered functional architecture** with strict effect boundaries:

```
HTTP (Phoenix/Plug) → Boundaries (Contexts) → Domain (Pure) → Infrastructure (Effects)
```

| Layer | Location | Rules |
|-------|----------|-------|
| **Domain** | `lib/gprint_ex/domain/` | Pure structs + functions. NO side effects, NO imports from other layers. |
| **Boundaries** | `lib/gprint_ex/boundaries/` | Public API contexts. Orchestrate domain + infrastructure. |
| **Infrastructure** | `lib/gprint_ex/infrastructure/` | Oracle DB, Keycloak, external integrations. All side effects here. |
| **Web** | `lib/gprint_ex_web/` | Controllers delegate to boundaries. Never call infrastructure directly. |

## Core Patterns

### Railway-Oriented Programming
All operations return `{:ok, value} | {:error, reason}`. Use `GprintEx.Result` for chaining:

```elixir
# Preferred: with for multi-step operations
with {:ok, customer} <- Customer.new(params),
     {:ok, id} <- CustomerQueries.insert(customer, user),
     {:ok, created} <- get_by_id(ctx, id) do
  {:ok, created}
end

# Result module helpers for transformations
Result.map({:ok, list}, &Enum.count/1)           # {:ok, 5}
Result.traverse(items, &process/1)               # Collect all or fail fast
Result.from_nilable(nil, :not_found)             # {:error, :not_found}
```

### Domain Struct Template
New domain modules must include these elements (see [customer.ex](lib/gprint_ex/domain/customer.ex)):

```elixir
defmodule GprintEx.Domain.Entity do
  @type t :: %__MODULE__{...}
  @enforce_keys [:tenant_id, :required_field]
  defstruct [...]

  @spec new(map()) :: {:ok, t()} | {:error, :validation_failed, [String.t()]}
  def new(params), do: with {:ok, v} <- validate(params), do: {:ok, struct!(__MODULE__, v)}

  # Placeholder validation function - implement to return {:ok, validated_params} or {:error, :validation_failed, [errors]}
  # Example: defp validate(params) do
  #   # Validate required fields, types, etc.
  #   # Return {:ok, params} or {:error, :validation_failed, ["error message"]}
  # end

  @spec from_row(map()) :: {:ok, t()} | {:error, term()}
  def from_row(row), do: ...  # Oracle row → struct

  @spec to_response(t()) :: map()
  def to_response(entity), do: ...  # Struct → JSON-safe map
end
```

### Tenant Context
All boundary operations require tenant context extracted from JWT:

```elixir
# In boundaries - always pattern match tenant context
@spec create(tenant_context(), map()) :: Result.t(Entity.t())
def create(%{tenant_id: tenant_id, user: user}, params), do: ...

# In controllers - extract via AuthPlug
ctx = AuthPlug.tenant_context(conn)  # %{tenant_id: _, user: _, login_session: _}
```

### Controller Pattern
Controllers delegate to boundaries and use `action_fallback`:

```elixir
use Phoenix.Controller
action_fallback GprintExWeb.FallbackController

def show(conn, %{"id" => id}) do
  ctx = AuthPlug.tenant_context(conn)
  with {:ok, entity} <- Entities.get_by_id(ctx, parse_int(id)) do  # parse_int/1 is a project-specific helper
    json(conn, %{success: true, data: Entity.to_response(entity)})
  end
  # Errors automatically handled by FallbackController
end
```

## Developer Workflow

```bash
make deps              # Install dependencies
make dev               # Start dev server with iex (hot reload)
make test.unit         # Fast domain tests (no DB, async)
make test.integration  # Tests with Oracle connection
make check             # format + credo --strict + dialyzer (MUST PASS before commit)
```

### Testing
- `test/domain/` - Pure unit tests with `async: true`
- `test/boundaries/` - Integration tests (require DB)
- Use factory: `build(:customer)`, `build(:contract, status: :active)`
- Domain tests should NOT mock - test pure functions directly

```elixir
# Good domain test
test "validates email format" do
  params = %{tenant_id: "t1", customer_code: "C1", name: "X", email: "invalid"}
  assert {:error, :validation_failed, errors} = Customer.new(params)
  assert "invalid email format" in errors
end
```

## Error Handling

| Error Type | Return Value | HTTP Status |
|------------|--------------|-------------|
| Validation | `{:error, :validation_failed, [strings]}` | 422 |
| Not found | `{:error, :not_found}` | 404 |
| Invalid transition | `{:error, :invalid_transition}` | 422 |
| Other | `{:error, reason}` | 500 (logged, generic response) |

## Oracle Database

- Uses `jamdb_oracle` with wallet authentication (NOT Ecto)
- Connection pool via DBConnection in [oracle_connection.ex](lib/gprint_ex/infrastructure/repo/oracle_connection.ex)
- Raw SQL queries in `infrastructure/repo/queries/*.ex`
- Row mapping: `%{column_name: value}` atoms (lowercase)
- Environment: `ORACLE_WALLET_PATH`, `ORACLE_TNS_ALIAS`, `ORACLE_USER`, `ORACLE_PASSWORD`

```elixir
# Query pattern in *_queries.ex modules
def find_by_id(tenant_id, id) do
  sql = "SELECT * FROM customers WHERE tenant_id = :1 AND id = :2"
  OracleConnection.query(:gprint_pool, sql, [tenant_id, id])
end
```

## Key Files

| Purpose | File |
|---------|------|
| Full architecture spec | [elixir-integration-spec.md](elixir-integration-spec.md) |
| Result utilities | [lib/gprint_ex/result.ex](lib/gprint_ex/result.ex) |
| Domain pattern example | [lib/gprint_ex/domain/customer.ex](lib/gprint_ex/domain/customer.ex) |
| Boundary pattern | [lib/gprint_ex/boundaries/customers.ex](lib/gprint_ex/boundaries/customers.ex) |
| Controller pattern | [lib/gprint_ex_web/controllers/customer_controller.ex](lib/gprint_ex_web/controllers/customer_controller.ex) |
| Error handling | [lib/gprint_ex_web/controllers/fallback_controller.ex](lib/gprint_ex_web/controllers/fallback_controller.ex) |
| Test factories | [test/support/factory.ex](test/support/factory.ex) |
