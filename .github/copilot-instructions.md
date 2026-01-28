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

## EIP & PL/SQL Integration

### Separation of Concerns
Elixir orchestrates integration workflows; PL/SQL owns data operations. Never embed business SQL in Elixir—call package functions instead.

```
External System → Elixir Extractor → ETL Pipeline → PL/SQL Validation
                                          ↓
                      PL/SQL Transform ← Rules
                                          ↓
                      PL/SQL Load → Target Tables → Audit
```

### PL/SQL Package Conventions

| Package | Purpose |
|---------|---------|
| `CONTRACT_PKG` | Contract CRUD, validation, bulk ops |
| `CUSTOMER_PKG` | Customer CRUD, upsert, tax validation |
| `ETL_PKG` | Staging sessions, transform, promote |
| `INTEGRATION_PKG` | Message routing, dedup, aggregation |

Call packages via bind variables using `OracleRepo.execute/2`:

```elixir
# lib/gprint_ex/integration/db/contract_operations.ex
def insert_contract(contract, user) do
  sql = """
  DECLARE
    v_contract contract_t;
    v_result NUMBER;
  BEGIN
    v_contract := contract_t(NULL, :1, :2, ...);
    v_result := contract_pkg.insert_contract(v_contract, :user);
    :out := v_result;
  END;
  """
  OracleRepo.execute(sql, [contract.tenant_id, contract.contract_number, ..., user, {:out, :number}])
end
```

### EIP Module Locations

| Pattern | Location |
|---------|----------|
| Message Channel | `lib/gprint_ex/integration/channels/` |
| Content-Based Router | `lib/gprint_ex/integration/routers/` |
| Message Translator | `lib/gprint_ex/integration/translators/` |
| ETL Pipeline | `lib/gprint_ex/etl/` |

### ETL Flow
1. **Create session** via `etl_pkg.create_staging_session` → `session_id`
2. **Load raw data** via `etl_pkg.load_to_staging`
3. **Transform** via `etl_pkg.transform_contracts` with rules CLOB
4. **Validate** via `etl_pkg.validate_staging_data` (pipelined)
5. **Promote** via `etl_pkg.promote_from_staging` to target tables
6. **Rollback** on failure via `etl_pkg.rollback_session`

### Idempotency & Dedup
Check `integration_pkg.is_duplicate_message/2` before processing; mark done with `mark_message_processed/3`. Use correlation IDs for aggregation.

### Error Handling in PL/SQL Calls
Wrap PL/SQL calls with retry + telemetry; map Oracle errors to domain errors:

```elixir
case OracleRepo.execute(sql, params) do
  {:ok, [id]} -> {:ok, id}
  {:error, %{code: 1, message: msg}} -> {:error, :unique_violation, msg}
  {:error, reason} -> {:error, :db_error, reason}
end
```

### Key Tables

| Table | Purpose |
|-------|---------|
| `etl_staging` | Raw/transformed staging rows |
| `etl_sessions` | Session metadata + counts |
| `integration_messages` | Message routing log |
| `message_dedup` | Idempotency window |
| `transform_audit` | Before/after audit trail |

### Testing EIP Modules
- Mock `OracleRepo.execute/2` for unit tests
- Integration tests use test DB with known staging sessions
- Property tests for translators (format round-trips)

### EIP Implementation Details

#### Message Channel
GenServer-based publish/subscribe with priority queues:

```elixir
alias GprintEx.Integration.Channels.{ChannelRegistry, MessageChannel}

# Get or create a channel
{:ok, channel} = ChannelRegistry.get_or_create(:contracts)

# Subscribe to messages
:ok = MessageChannel.subscribe(channel, self())

# Publish a message
message = Message.new!(%{type: "CONTRACT_CREATE", payload: data})
:ok = MessageChannel.publish(channel, message)
```

#### Content-Based Router
Route messages based on content:

```elixir
alias GprintEx.Integration.Routers.ContentBasedRouter

rules = [
  %{condition: {:field_equals, :message_type, "CONTRACT_CREATE"}, destination: :contracts},
  %{condition: {:field_matches, :message_type, ~r/CUSTOMER_.*/}, destination: :customers},
  %{condition: :default, destination: :unrouted}
]

{:ok, destination} = ContentBasedRouter.route(message, rules)
```

#### Message Translator
Convert between formats:

```elixir
alias GprintEx.Integration.Translators.{ContractTranslator, FormatTranslator}

# External format to domain
{:ok, contract} = ContractTranslator.from_external(data, :salesforce)

# Domain to API response
{:ok, json} = ContractTranslator.to_external(contract, :api_response)

# Generic format conversion
{:ok, map} = FormatTranslator.convert(json_string, :json, :map)
```

#### ETL Pipeline
Declarative pipeline definition:

```elixir
alias GprintEx.ETL.Pipeline
alias GprintEx.ETL.Extractors.FileExtractor
alias GprintEx.ETL.Transformers.ContractTransformer
alias GprintEx.ETL.Loaders.StagingLoader

pipeline = Pipeline.new("contract_import")
|> Pipeline.add_extractor(FileExtractor, file: "contracts.csv", format: :csv)
|> Pipeline.add_transformer(ContractTransformer, validation: :strict)
|> Pipeline.add_loader(StagingLoader, entity_type: :contract)

{:ok, result} = Pipeline.run(pipeline, %{tenant_id: tenant_id, user: user})
```

#### Integration DB Operations
Call PL/SQL packages:

```elixir
alias GprintEx.Integration.DB.{ContractOperations, ETLOperations, IntegrationOperations}

# Contract operations
{:ok, id} = ContractOperations.insert(contract, user)
{:ok, contract} = ContractOperations.update_status(tenant_id, id, :active, user)

# ETL session management
{:ok, session_id} = ETLOperations.create_session(tenant_id, "SALESFORCE", user)
{:ok, _} = ETLOperations.bulk_load_to_staging(session_id, "CONTRACT", records)
{:ok, _} = ETLOperations.transform_contracts(session_id, rules)
{:ok, issues} = ETLOperations.validate_staging_data(session_id)
{:ok, count} = ETLOperations.promote_contracts(session_id, user)

# Integration message handling
is_dup = IntegrationOperations.is_duplicate?(message_id, hash)
:ok = IntegrationOperations.mark_processed(message_id, hash, user)
```

### Key EIP Files

| Module | File | Purpose |
|--------|------|---------|
| Message | `lib/gprint_ex/integration/message.ex` | Core message struct |
| MessageChannel | `lib/gprint_ex/integration/channels/message_channel.ex` | Pub/sub GenServer |
| ChannelRegistry | `lib/gprint_ex/integration/channels/channel_registry.ex` | Dynamic channel management |
| ContentBasedRouter | `lib/gprint_ex/integration/routers/content_based_router.ex` | Content routing |
| DynamicRouter | `lib/gprint_ex/integration/routers/dynamic_router.ex` | Runtime routing tables |
| ContractTranslator | `lib/gprint_ex/integration/translators/contract_translator.ex` | Contract format conversion |
| Pipeline | `lib/gprint_ex/etl/pipeline.ex` | ETL orchestration |
| ContractOperations | `lib/gprint_ex/integration/db/contract_operations.ex` | PL/SQL CONTRACT_PKG wrapper |
| ETLOperations | `lib/gprint_ex/integration/db/etl_operations.ex` | PL/SQL ETL_PKG wrapper |
| IntegrationOperations | `lib/gprint_ex/integration/db/integration_operations.ex` | PL/SQL INTEGRATION_PKG wrapper |

### PL/SQL Migrations

Apply migrations in order:

```bash
# Types and objects
sqlplus user/pass@tns @priv/oracle/migrations/001_create_eip_types.sql

# Tables and indexes  
sqlplus user/pass@tns @priv/oracle/migrations/002_create_eip_tables.sql

# Packages
sqlplus user/pass@tns @priv/oracle/packages/contract_pkg.sql
sqlplus user/pass@tns @priv/oracle/packages/customer_pkg.sql
sqlplus user/pass@tns @priv/oracle/packages/etl_pkg.sql
sqlplus user/pass@tns @priv/oracle/packages/integration_pkg.sql
```
