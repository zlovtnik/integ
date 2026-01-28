# GprintEx - AI Coding Instructions

> Contract Lifecycle Management (CLM) service: Functional-first Elixir with Oracle ADB backend and Keycloak auth.

## Architecture

**Layered functional architecture** with strict effect boundaries:

```
HTTP (Phoenix/Plug) → Boundaries (Contexts) → Domain (Pure) → Infrastructure (Effects)
```

- **Domain** (`lib/gprint_ex/domain/`): Pure structs + functions, NO side effects. Validation, transformations, state machines.
- **Boundaries** (`lib/gprint_ex/boundaries/`): Public API contexts that orchestrate domain logic with infra effects.
- **Infrastructure** (`lib/gprint_ex/infrastructure/`): Oracle DB, Keycloak auth, external integrations.
- **Web** (`lib/gprint_ex_web/`): Controllers delegate to boundaries, use `action_fallback` for error handling.

## Core Patterns

### Railway-Oriented Programming (Result Tuples)
All operations return `{:ok, value} | {:error, reason}`. Use `GprintEx.Result` for chaining:

```elixir
# Chain with flat_map or with
with {:ok, customer} <- Customer.new(params),
     {:ok, id} <- CustomerQueries.insert(customer, user),
     {:ok, created} <- get_by_id(ctx, id) do
  {:ok, created}
end
```

Key `Result` functions: `map/2`, `flat_map/2`, `sequence/1`, `traverse/2`, `from_nilable/2`

### Domain Structs
Always include `@type t`, `@enforce_keys`, `new/1` with validation, `from_row/1` for DB mapping:

```elixir
@spec new(map()) :: {:ok, t()} | {:error, :validation_failed, [String.t()]}
def new(params), do: with {:ok, validated} <- validate(params), do: {:ok, struct!(__MODULE__, validated)}
```

### Tenant Context
All boundary operations require tenant context from JWT:
```elixir
@type tenant_context :: %{tenant_id: String.t(), user: String.t()}
def create(%{tenant_id: tenant_id, user: user}, params), do: ...
```

Controllers extract via `AuthPlug.tenant_context(conn)`.

## Developer Workflow

```bash
make deps          # Install dependencies
make dev           # Start dev server with iex
make test.unit     # Fast domain tests (no DB)
make test.integration  # Tests with Oracle connection
make check         # format + credo --strict + dialyzer
```

**Quality gates before commit:** `make check` must pass.

### Testing Structure
- `test/domain/` - Pure function unit tests (async: true)
- `test/boundaries/` - Context integration tests
- `test/gprint_ex_web/` - HTTP endpoint tests
- `test/support/factory.ex` - Use `build(:customer)`, `build(:contract)`, etc.

## Code Conventions

1. **Validation errors** return `{:error, :validation_failed, [error_strings]}`
2. **Not found** returns `{:error, :not_found}`
3. **Domain modules** have `to_response/1` for API serialization
4. **Controllers** use `action_fallback GprintExWeb.FallbackController`
5. **Typespecs** required on all public functions
6. **Pipe-friendly** - design functions for pipeline composition

## Oracle Database

- Uses `jamdb_oracle` with wallet authentication (no Ecto)
- Connection pool via `poolboy` in `OracleRepo`
- Raw SQL in `infrastructure/repo/queries/` modules
- Row → struct mapping in domain `from_row/1` functions
- Environment: `ORACLE_WALLET_PATH`, `ORACLE_TNS_ALIAS`, `ORACLE_USER`, `ORACLE_PASSWORD`

## Key Files

- [elixir-integration-spec.md](elixir-integration-spec.md) - Full architecture spec with code examples
- [lib/gprint_ex/result.ex](lib/gprint_ex/result.ex) - Result monad utilities
- [lib/gprint_ex/domain/customer.ex](lib/gprint_ex/domain/customer.ex) - Domain struct pattern example
- [lib/gprint_ex/boundaries/customers.ex](lib/gprint_ex/boundaries/customers.ex) - Context API pattern
- [test/support/factory.ex](test/support/factory.ex) - Test data builders
