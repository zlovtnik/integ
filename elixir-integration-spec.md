# Elixir Integration Spec — Contract Lifecycle Management Service

> **Functional-First. Immutable Core. Oracle Backend.**
>
> A pure functional Elixir service for contract printing and lifecycle management, connecting to Oracle ADB via wallet authentication with Keycloak OAuth2 authorization.

---

## Table of Contents

1. [Philosophy](#philosophy)
2. [Architecture](#architecture)
3. [Core Functional Patterns](#core-functional-patterns)
4. [Oracle Database Integration](#oracle-database-integration)
5. [Keycloak Authentication](#keycloak-authentication)
6. [Domain Modules](#domain-modules)
7. [Error Handling](#error-handling)
8. [API Specification](#api-specification)
9. [Configuration](#configuration)
10. [Testing Strategy](#testing-strategy)
11. [Makefile Reference](#makefile-reference)

---

## Philosophy

### Functional Commandments

1. **Data flows, never mutates** — All transformations return new data
2. **Functions are first-class citizens** — Compose, pipe, curry
3. **Side effects at the edges** — Pure core, impure shell
4. **Pattern match everything** — Explicit over implicit
5. **Railway-oriented programming** — `{:ok, _}` | `{:error, _}` chains
6. **Immutability as default** — No mutable state in business logic
7. **Process isolation** — Each tenant context is isolated
8. **Declarative over imperative** — Describe *what*, not *how*

### Why Elixir for CLM?

```elixir
# Data pipelines as first-class citizens
contract
|> Contracts.validate_terms()
|> Contracts.calculate_totals()
|> Contracts.apply_template()
|> Contracts.generate_document()
|> case do
  {:ok, document} -> Repo.insert_generated(document)
  {:error, _} = err -> err
end
```

---

## Architecture

### Layered Functional Architecture

```
┌─────────────────────────────────────────────────────────────────────┐
│                         HTTP Layer (Plug/Phoenix)                   │
│                                                                     │
│    Request → Router → Plug Pipeline → Controller → Response        │
├─────────────────────────────────────────────────────────────────────┤
│                        Boundary Layer (Contexts)                    │
│                                                                     │
│    Contracts   │   Customers   │   Services   │   Generation       │
│    (pure API)  │   (pure API)  │  (pure API)  │   (pure API)        │
├─────────────────────────────────────────────────────────────────────┤
│                          Domain Core                                │
│                                                                     │
│    Pure Functions   │   Structs   │   Behaviours   │   Protocols   │
│    (no side effects)                                                │
├─────────────────────────────────────────────────────────────────────┤
│                        Infrastructure                               │
│                                                                     │
│    OracleRepo   │   Keycloak   │   DocumentStore   │   Telemetry   │
│    (effects boundary)                                               │
└─────────────────────────────────────────────────────────────────────┘
```

### Project Structure

```
gprint_ex/
├── lib/
│   ├── gprint_ex/
│   │   ├── application.ex              # OTP Application
│   │   │
│   │   ├── domain/                     # Pure Domain (NO dependencies)
│   │   │   ├── customer.ex             # Customer struct + functions
│   │   │   ├── contract.ex             # Contract struct + functions
│   │   │   ├── service.ex              # Service struct + functions
│   │   │   ├── contract_item.ex        # Contract line items
│   │   │   ├── party.ex                # CLM Party (org/individual)
│   │   │   ├── obligation.ex           # Contract obligations
│   │   │   ├── workflow.ex             # Workflow state machine
│   │   │   └── types.ex                # Shared types (tenant_id, etc.)
│   │   │
│   │   ├── boundaries/                 # Context APIs (effect boundary)
│   │   │   ├── customers.ex            # Customer operations
│   │   │   ├── contracts.ex            # Contract operations
│   │   │   ├── services.ex             # Service catalog
│   │   │   ├── generation.ex           # Document generation
│   │   │   ├── clm.ex                  # CLM orchestration
│   │   │   └── print_jobs.ex           # Print queue management
│   │   │
│   │   ├── infrastructure/             # External integrations
│   │   │   ├── repo/
│   │   │   │   ├── oracle_repo.ex      # Oracle connection pool
│   │   │   │   ├── queries/            # Raw SQL modules
│   │   │   │   │   ├── customer_queries.ex
│   │   │   │   │   ├── contract_queries.ex
│   │   │   │   │   └── clm_queries.ex
│   │   │   │   └── mappers/            # Row → Struct mappers
│   │   │   │       ├── customer_mapper.ex
│   │   │   │       └── contract_mapper.ex
│   │   │   │
│   │   │   ├── auth/
│   │   │   │   ├── keycloak_client.ex  # Keycloak OAuth2
│   │   │   │   ├── jwt_validator.ex    # Token validation
│   │   │   │   └── claims.ex           # JWT claims struct
│   │   │   │
│   │   │   └── document_store/
│   │   │       └── s3_store.ex         # Object storage
│   │   │
│   │   └── telemetry.ex                # Metrics & tracing
│   │
│   └── gprint_ex_web/
│       ├── router.ex                   # Route definitions
│       ├── plugs/
│       │   ├── auth_plug.ex            # JWT extraction
│       │   ├── tenant_plug.ex          # Tenant context
│       │   └── request_id_plug.ex      # Correlation ID
│       │
│       ├── controllers/
│       │   ├── customer_controller.ex
│       │   ├── contract_controller.ex
│       │   ├── service_controller.ex
│       │   ├── generation_controller.ex
│       │   └── health_controller.ex
│       │
│       └── views/                      # JSON serialization
│
├── config/
│   ├── config.exs                      # Base config
│   ├── dev.exs                         # Development
│   ├── test.exs                        # Test
│   ├── runtime.exs                     # Runtime (env vars)
│   └── releases.exs                    # Release config
│
├── priv/
│   └── wallet/                         # Oracle wallet (git-ignored)
│
├── test/
│   ├── support/
│   │   ├── factory.ex                  # Test data factories
│   │   └── oracle_sandbox.ex           # Transaction isolation
│   │
│   ├── domain/                         # Pure function tests
│   ├── boundaries/                     # Integration tests
│   └── gprint_ex_web/                  # HTTP tests
│
├── mix.exs
├── Makefile
└── .envrc                              # direnv (git-ignored)
```

---

## Core Functional Patterns

### Pattern 1: Result Tuples (Railway-Oriented)

```elixir
defmodule GprintEx.Result do
  @moduledoc """
  Railway-oriented programming utilities.
  All operations return {:ok, value} | {:error, reason}.
  """

  @type t(a) :: {:ok, a} | {:error, term()}
  @type t :: t(any())

  @doc "Map over success value"
  @spec map(t(a), (a -> b)) :: t(b) when a: var, b: var
  def map({:ok, value}, fun), do: {:ok, fun.(value)}
  def map({:error, _} = err, _fun), do: err

  @doc "Flat map (bind) for chaining operations"
  @spec flat_map(t(a), (a -> t(b))) :: t(b) when a: var, b: var
  def flat_map({:ok, value}, fun), do: fun.(value)
  def flat_map({:error, _} = err, _fun), do: err

  @doc "Extract value or raise (logs error safely, does not expose reason in exception)"
  @spec unwrap!(t(a)) :: a when a: var
  def unwrap!({:ok, value}), do: value
  def unwrap!({:error, reason}) do
    # Log the actual reason securely (can be filtered/masked in log config)
    Logger.error("Result.unwrap! failed", error: inspect(reason, limit: 50))
    raise "Unwrap failed"
  end

  @doc "Extract value or default"
  @spec unwrap_or(t(a), a) :: a when a: var
  def unwrap_or({:ok, value}, _default), do: value
  def unwrap_or({:error, _}, default), do: default

  @doc "Sequence a list of results"
  @spec sequence([t(a)]) :: t([a]) when a: var
  def sequence(results) do
    Enum.reduce_while(results, {:ok, []}, fn
      {:ok, value}, {:ok, acc} -> {:cont, {:ok, [value | acc]}}
      {:error, _} = err, _acc -> {:halt, err}
    end)
    |> map(&Enum.reverse/1)
  end

  @doc "Traverse a list with a result-returning function"
  @spec traverse([a], (a -> t(b))) :: t([b]) when a: var, b: var
  def traverse(list, fun) do
    list
    |> Enum.map(fun)
    |> sequence()
  end
end
```

### Pattern 2: Typed Structs with Validation

```elixir
defmodule GprintEx.Domain.Customer do
  @moduledoc """
  Customer domain entity.
  Pure data structure with validation functions.
  """

  alias GprintEx.Domain.Types

  @type customer_type :: :individual | :company
  @type status :: :active | :inactive

  @type t :: %__MODULE__{
    id: pos_integer() | nil,
    tenant_id: Types.tenant_id(),
    customer_code: String.t(),
    customer_type: customer_type(),
    name: String.t(),
    trade_name: String.t() | nil,
    tax_id: String.t() | nil,
    email: String.t() | nil,
    phone: String.t() | nil,
    address: Types.address() | nil,
    active: boolean(),
    created_at: DateTime.t() | nil,
    updated_at: DateTime.t() | nil
  }

  @enforce_keys [:tenant_id, :customer_code, :name]
  defstruct [
    :id,
    :tenant_id,
    :customer_code,
    :customer_type,
    :name,
    :trade_name,
    :tax_id,
    :email,
    :phone,
    :address,
    :active,
    :created_at,
    :updated_at
  ]

  @doc "Create a new customer from validated params"
  @spec new(map()) :: {:ok, t()} | {:error, :validation_failed, [String.t()]}
  def new(params) when is_map(params) do
    with {:ok, validated} <- validate(params) do
      {:ok, struct!(__MODULE__, validated)}
    end
  end

  @doc "Validate customer params"
  @spec validate(map()) :: {:ok, map()} | {:error, :validation_failed, [String.t()]}
  def validate(params) do
    errors =
      []
      |> validate_required(params, :tenant_id)
      |> validate_required(params, :customer_code)
      |> validate_required(params, :name)
      |> validate_email(params)
      |> validate_tax_id(params)

    case errors do
      [] ->
        {:ok, normalize_params(params)}
      errors ->
        {:error, :validation_failed, errors}
    end
  end

  # Pure validation functions
  defp validate_required(errors, params, key) do
    case Map.get(params, key) || Map.get(params, to_string(key)) do
      nil -> ["#{key} is required" | errors]
      "" -> ["#{key} is required" | errors]
      _ -> errors
    end
  end

  # Email validation using email_checker library for RFC-5322 compliance
  # Add {:email_checker, "~> 0.2"} to mix.exs deps
  # Optional: enable MX lookup via config :email_checker, :validations, [EmailChecker.Check.Format, EmailChecker.Check.MX]
  defp validate_email(errors, %{email: email}) when is_binary(email) do
    case validate_email_format(email) do
      :ok -> errors
      {:error, _reason} -> ["invalid email format" | errors]
    end
  end
  defp validate_email(errors, _), do: errors

  # Use email_checker for robust RFC-5322 validation
  # Falls back to comprehensive regex if library unavailable
  defp validate_email_format(email) do
    if Code.ensure_loaded?(EmailChecker) do
      # Use email_checker library (supports MX lookup if configured)
      if EmailChecker.valid?(email), do: :ok, else: {:error, :invalid_format}
    else
      # Fallback: comprehensive RFC-5322 based regex
      # Handles quoted strings, IP literals, comments, and international domains
      rfc5322_regex = ~r/^(?:[a-z0-9!#$%&'*+\/=?^_`{|}~-]+(?:\.[a-z0-9!#$%&'*+\/=?^_`{|}~-]+)*|"(?:[\x01-\x08\x0b\x0c\x0e-\x1f\x21\x23-\x5b\x5d-\x7f]|\\[\x01-\x09\x0b\x0c\x0e-\x7f])*")@(?:(?:[a-z0-9](?:[a-z0-9-]*[a-z0-9])?\.)+[a-z0-9](?:[a-z0-9-]*[a-z0-9])?|\[(?:(?:25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\.){3}(?:25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?|[a-z0-9-]*[a-z0-9]:(?:[\x01-\x08\x0b\x0c\x0e-\x1f\x21-\x5a\x53-\x7f]|\\[\x01-\x09\x0b\x0c\x0e-\x7f])+)\])$/i

      if Regex.match?(rfc5322_regex, email), do: :ok, else: {:error, :invalid_format}
    end
  end

  defp validate_tax_id(errors, %{tax_id: tax_id, customer_type: :company})
       when is_binary(tax_id) do
    digits = String.replace(tax_id, ~r/\D/, "")
    if String.length(digits) == 14 do
      errors
    else
      ["company tax_id (CNPJ) must have 14 digits" | errors]
    end
  end
  defp validate_tax_id(errors, %{tax_id: tax_id, customer_type: :individual})
       when is_binary(tax_id) do
    digits = String.replace(tax_id, ~r/\D/, "")
    if String.length(digits) == 11 do
      errors
    else
      ["individual tax_id (CPF) must have 11 digits" | errors]
    end
  end
  defp validate_tax_id(errors, _), do: errors

  defp normalize_params(params) do
    params
    |> Map.put(:customer_type, normalize_customer_type(params[:customer_type]))
    |> Map.put(:active, Map.get(params, :active, true))
  end

  defp normalize_customer_type("INDIVIDUAL"), do: :individual
  defp normalize_customer_type("COMPANY"), do: :company
  defp normalize_customer_type(:individual), do: :individual
  defp normalize_customer_type(:company), do: :company
  defp normalize_customer_type(_), do: :individual

  # Transformation functions (pure)

  @doc "Get display name (trade_name or name)"
  @spec display_name(t()) :: String.t()
  def display_name(%__MODULE__{trade_name: nil, name: name}), do: name
  def display_name(%__MODULE__{trade_name: trade_name}), do: trade_name

  @doc "Format tax_id for display (CPF/CNPJ)"
  @spec formatted_tax_id(t()) :: String.t() | nil
  def formatted_tax_id(%__MODULE__{tax_id: nil}), do: nil
  def formatted_tax_id(%__MODULE__{tax_id: tax_id}) do
    digits = String.replace(tax_id, ~r/\D/, "")
    case String.length(digits) do
      11 ->
        # CPF: 000.000.000-00
        String.replace(digits, ~r/(\d{3})(\d{3})(\d{3})(\d{2})/, "\\1.\\2.\\3-\\4")
      14 ->
        # CNPJ: 00.000.000/0000-00
        String.replace(digits, ~r/(\d{2})(\d{3})(\d{3})(\d{4})(\d{2})/, "\\1.\\2.\\3/\\4-\\5")
      _ ->
        tax_id
    end
  end

  @doc "Convert to API response map"
  @spec to_response(t()) :: map()
  def to_response(%__MODULE__{} = customer) do
    %{
      id: customer.id,
      customer_code: customer.customer_code,
      customer_type: Atom.to_string(customer.customer_type) |> String.upcase(),
      name: customer.name,
      trade_name: customer.trade_name,
      display_name: display_name(customer),
      tax_id: customer.tax_id,
      formatted_tax_id: formatted_tax_id(customer),
      email: customer.email,
      phone: customer.phone,
      address: customer.address,
      active: customer.active,
      created_at: customer.created_at,
      updated_at: customer.updated_at
    }
  end
end
```

### Pattern 3: Pipelines with `with`

```elixir
defmodule GprintEx.Boundaries.Contracts do
  @moduledoc """
  Contract context — public API for contract operations.
  Orchestrates domain logic with repository effects.
  """

  alias GprintEx.Domain.{Contract, ContractItem}
  alias GprintEx.Infrastructure.Repo.{ContractQueries, OracleRepo}
  alias GprintEx.Result

  @type tenant_context :: %{tenant_id: String.t(), user: String.t()}

  @doc "Create a new contract with items"
  @spec create(tenant_context(), map()) :: Result.t(Contract.t())
  def create(%{tenant_id: tenant_id, user: user} = _ctx, params) do
    with {:ok, contract} <- Contract.new(Map.put(params, :tenant_id, tenant_id)),
         {:ok, items} <- validate_items(params[:items] || []),
         {:ok, contract_with_totals} <- Contract.calculate_totals(contract, items),
         {:ok, contract_id} <- OracleRepo.transaction(fn ->
           with {:ok, id} <- ContractQueries.insert(contract_with_totals, user),
                :ok <- insert_items(tenant_id, id, items) do
             {:ok, id}
           end
         end),
         {:ok, created} <- get_by_id(%{tenant_id: tenant_id}, contract_id) do
      {:ok, created}
    end
  end

  @doc "Get contract by ID"
  @spec get_by_id(tenant_context(), pos_integer()) :: Result.t(Contract.t())
  def get_by_id(%{tenant_id: tenant_id}, id) do
    case ContractQueries.find_by_id(tenant_id, id) do
      {:ok, nil} -> {:error, :not_found}
      {:ok, row} -> Contract.from_row(row)
      {:error, _} = err -> err
    end
  end

  @doc "List contracts with filters"
  @spec list(tenant_context(), keyword()) :: Result.t([Contract.t()])
  def list(%{tenant_id: tenant_id}, opts \\ []) do
    filters = Keyword.put(opts, :tenant_id, tenant_id)

    with {:ok, rows} <- ContractQueries.list(filters) do
      Result.traverse(rows, &Contract.from_row/1)
    end
  end

  @doc "Transition contract status (state machine)"
  @spec transition_status(tenant_context(), pos_integer(), atom()) :: Result.t(Contract.t())
  def transition_status(%{tenant_id: tenant_id, user: user}, id, new_status) do
    with {:ok, contract} <- get_by_id(%{tenant_id: tenant_id}, id),
         {:ok, transitioned} <- Contract.transition(contract, new_status),
         :ok <- ContractQueries.update_status(tenant_id, id, new_status, user),
         :ok <- log_history(tenant_id, id, :status_change, contract.status, new_status, user) do
      {:ok, transitioned}
    end
  end

  # Private helpers

  defp validate_items(items) do
    items
    |> Enum.with_index(1)
    |> Result.traverse(fn {item, idx} ->
      case ContractItem.new(item) do
        {:ok, _} = ok -> ok
        {:error, :validation_failed, errors} ->
          {:error, {:item_validation_failed, idx, errors}}
      end
    end)
  end

  defp insert_items(_tenant_id, _contract_id, []), do: :ok
  defp insert_items(tenant_id, contract_id, items) do
    # Use reduce_while to stop on first error and propagate failure
    Enum.reduce_while(items, :ok, fn item, :ok ->
      case ContractQueries.insert_item(tenant_id, contract_id, item) do
        :ok -> {:cont, :ok}
        {:ok, _} -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, {:insert_item_failed, reason}}}
      end
    end)
  end

  defp log_history(tenant_id, contract_id, action, old_value, new_value, user) do
    ContractQueries.insert_history(%{
      tenant_id: tenant_id,
      contract_id: contract_id,
      action: action,
      field_changed: "status",
      old_value: to_string(old_value),
      new_value: to_string(new_value),
      performed_by: user
    })
  end
end
```

### Pattern 4: Protocol-Based Polymorphism

```elixir
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

defimpl GprintEx.Domain.Auditable, for: GprintEx.Domain.Contract do
  def entity_type(_), do: "CONTRACT"
  def entity_id(%{id: id}), do: id
  def to_audit_snapshot(contract) do
    %{
      contract_number: contract.contract_number,
      status: contract.status,
      total_value: contract.total_value,
      customer_id: contract.customer_id
    }
  end
end

defimpl GprintEx.Domain.Auditable, for: GprintEx.Domain.Customer do
  def entity_type(_), do: "CUSTOMER"
  def entity_id(%{id: id}), do: id
  def to_audit_snapshot(customer) do
    %{
      customer_code: customer.customer_code,
      name: customer.name,
      active: customer.active
    }
  end
end
```

### Pattern 5: Behaviour for Repositories

```elixir
defmodule GprintEx.Infrastructure.Repo.Behaviour do
  @moduledoc """
  Behaviour for repository implementations.
  Enables testing with mocks.
  """

  @type tenant_id :: String.t()
  @type id :: pos_integer()
  @type row :: map()
  @type filters :: keyword()

  @callback find_by_id(tenant_id(), id()) :: {:ok, row() | nil} | {:error, term()}
  @callback list(filters()) :: {:ok, [row()]} | {:error, term()}
  @callback insert(map(), String.t()) :: {:ok, id()} | {:error, term()}
  @callback update(tenant_id(), id(), map(), String.t()) :: :ok | {:error, term()}
  @callback delete(tenant_id(), id()) :: :ok | {:error, term()}
end
```

---

## Oracle Database Integration

### Connection via Wallet

```elixir
defmodule GprintEx.Infrastructure.Repo.OracleRepoSupervisor do
  @moduledoc """
  Supervisor for Oracle database connection pool using wallet authentication.

  Environment Configuration (must be set before app start):
  - ORACLE_WALLET_PATH: Path to wallet directory
  - ORACLE_TNS_ALIAS: TNS alias (e.g., mydb_high)
  - ORACLE_USER: Database username
  - ORACLE_PASSWORD: Database password
  - TNS_ADMIN: Must be set at application startup (see Application module)

  Note: TNS_ADMIN is set once at application startup, not per-worker,
  to avoid race conditions in multi-tenant scenarios.
  """

  use Supervisor

  require Logger

  @pool_name :oracle_pool
  @default_pool_size 10

  # Client API

  @doc "Start the Oracle connection pool supervisor"
  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Execute a query with positional parameters"
  @spec query(String.t(), [term()]) :: {:ok, [map()]} | {:error, term()}
  def query(sql, params \\ []) do
    :poolboy.transaction(@pool_name, fn worker ->
      GenServer.call(worker, {:query, sql, params}, :infinity)
    end)
  end

  @doc "Execute a query returning single row"
  @spec query_one(String.t(), [term()]) :: {:ok, map() | nil} | {:error, term()}
  def query_one(sql, params \\ []) do
    case query(sql, params) do
      {:ok, [row | _]} -> {:ok, row}
      {:ok, []} -> {:ok, nil}
      {:error, _} = err -> err
    end
  end

  @doc "Execute an insert/update/delete"
  @spec execute(String.t(), [term()]) :: :ok | {:ok, term()} | {:error, term()}
  def execute(sql, params \\ []) do
    :poolboy.transaction(@pool_name, fn worker ->
      GenServer.call(worker, {:execute, sql, params}, :infinity)
    end)
  end

  @doc "Execute within a transaction"
  @spec transaction((() -> {:ok, term()} | {:error, term()})) ::
          {:ok, term()} | {:error, term()}
  def transaction(fun) when is_function(fun, 0) do
    :poolboy.transaction(@pool_name, fn worker ->
      GenServer.call(worker, {:transaction, fun}, :infinity)
    end)
  end

  # Server callbacks

  @impl true
  def init(opts) do
    pool_size = Keyword.get(opts, :pool_size, @default_pool_size)

    pool_config = [
      name: {:local, @pool_name},
      worker_module: GprintEx.Infrastructure.Repo.OracleWorker,
      size: pool_size,
      max_overflow: div(pool_size, 2)
    ]

    worker_config = build_connection_config()

    children = [
      :poolboy.child_spec(@pool_name, pool_config, worker_config)
    ]

    Supervisor.start_link(children, strategy: :one_for_one)
  end

  defp build_connection_config do
    wallet_path = System.get_env("ORACLE_WALLET_PATH") ||
      raise "ORACLE_WALLET_PATH not set"
    tns_alias = System.get_env("ORACLE_TNS_ALIAS") ||
      raise "ORACLE_TNS_ALIAS not set"
    user = System.get_env("ORACLE_USER") ||
      raise "ORACLE_USER not set"
    password = System.get_env("ORACLE_PASSWORD") ||
      raise "ORACLE_PASSWORD not set"

    %{
      wallet_path: wallet_path,
      tns_alias: tns_alias,
      user: user,
      password: password
    }
  end
end
```

### Oracle Worker (uses Jamdb.Oracle)

```elixir
defmodule GprintEx.Infrastructure.Repo.OracleWorker do
  @moduledoc """
  Individual Oracle connection worker.
  Uses jamdb_oracle for native Elixir Oracle connectivity.
  """

  use GenServer

  require Logger

  def start_link(config) do
    GenServer.start_link(__MODULE__, config)
  end

  @impl true
  def init(config) do
    # NOTE: TNS_ADMIN must be set once at application startup (in Application.start/2)
    # to avoid race conditions. Do NOT call System.put_env here per-worker.
    # Example in Application module:
    #   System.put_env("TNS_ADMIN", Application.get_env(:gprint_ex, :oracle_wallet_path))
    #
    # The wallet_path is passed explicitly to connection options below.

    conn_opts = [
      hostname: config.tns_alias,
      username: config.user,
      password: config.password,
      timeout: 30_000,
      # Use wallet for SSL - pass path explicitly, no global env mutation
      ssl: [
        cacertfile: Path.join(config.wallet_path, "cwallet.sso")
      ],
      # Pass wallet path to driver if supported
      wallet_path: config.wallet_path
    ]

    case Jamdb.Oracle.start_link(conn_opts) do
      {:ok, conn} ->
        Logger.info("Oracle connection established to #{config.tns_alias}")
        {:ok, %{conn: conn, config: config}}

      {:error, reason} ->
        Logger.error("Oracle connection failed: #{inspect(reason)}")
        {:stop, reason}
    end
  end

  @impl true
  def handle_call({:query, sql, params}, _from, %{conn: conn} = state) do
    result = execute_query(conn, sql, params)
    {:reply, result, state}
  end

  def handle_call({:execute, sql, params}, _from, %{conn: conn} = state) do
    result = execute_statement(conn, sql, params)
    {:reply, result, state}
  end

  def handle_call({:transaction, fun}, _from, %{conn: conn} = state) do
    result = execute_transaction(conn, fun)
    {:reply, result, state}
  end

  # Private functions

  defp execute_query(conn, sql, params) do
    case Jamdb.Oracle.query(conn, sql, params) do
      {:ok, %{columns: columns, rows: rows}} ->
        mapped = Enum.map(rows, fn row ->
          columns
          |> Enum.zip(row)
          |> Map.new(fn {col, val} ->
            {String.downcase(col) |> String.to_atom(), normalize_value(val)}
          end)
        end)
        {:ok, mapped}

      {:error, reason} ->
        Logger.error("Query failed: #{inspect(reason)}")
        {:error, {:query_failed, reason}}
    end
  end

  defp execute_statement(conn, sql, params) do
    case Jamdb.Oracle.query(conn, sql, params) do
      {:ok, %{num_rows: _}} -> :ok
      {:ok, %{returning: [id]}} -> {:ok, id}
      {:error, reason} -> {:error, {:execute_failed, reason}}
    end
  end

  defp execute_transaction(conn, fun) do
    with :ok <- Jamdb.Oracle.query(conn, "SAVEPOINT txn_start", []),
         result <- fun.() do
      case result do
        {:ok, value} ->
          Jamdb.Oracle.query(conn, "COMMIT", [])
          {:ok, value}

        {:error, reason} ->
          Jamdb.Oracle.query(conn, "ROLLBACK TO txn_start", [])
          {:error, reason}
      end
    end
  end

  # Oracle type normalization
  #
  # IMPORTANT: Timezone handling for {:timestamp, ts}
  # This assumes Oracle session timezone is UTC. If your Oracle database uses
  # a different timezone, either:
  # 1. Configure Oracle session to use UTC: ALTER SESSION SET TIME_ZONE = 'UTC'
  # 2. Pass timezone via config: Application.get_env(:gprint_ex, :oracle_timezone, "Etc/UTC")
  # 3. Use TIMESTAMP WITH TIME ZONE columns in Oracle for explicit timezone storage
  #
  @oracle_timezone Application.compile_env(:gprint_ex, :oracle_timezone, "Etc/UTC")

  defp normalize_value(nil), do: nil
  defp normalize_value({:datetime, dt}), do: NaiveDateTime.from_erl!(dt)
  defp normalize_value({:timestamp, ts}) do
    naive = NaiveDateTime.from_erl!(ts)
    case DateTime.from_naive(naive, @oracle_timezone) do
      {:ok, dt} -> dt
      {:error, _} ->
        # Fallback: if timezone invalid, use UTC and log warning
        Logger.warning("Invalid oracle_timezone config, using UTC")
        DateTime.from_naive!(naive, "Etc/UTC")
    end
  end
  defp normalize_value({:clob, data}), do: data
  defp normalize_value(val), do: val
end
```

### Query Modules (Raw SQL)

```elixir
defmodule GprintEx.Infrastructure.Repo.Queries.CustomerQueries do
  @moduledoc """
  Raw SQL queries for customers table.
  Uses Oracle positional parameters (:1, :2, etc.)
  """

  alias GprintEx.Infrastructure.Repo.OracleRepo

  @base_select """
  SELECT
    id, tenant_id, customer_code, customer_type,
    name, trade_name, tax_id, state_reg, municipal_reg,
    email, phone, mobile,
    address_street, address_number, address_comp,
    address_district, address_city, address_state,
    address_zip, address_country,
    active, notes, created_at, updated_at,
    created_by, updated_by
  FROM customers
  """

  @spec find_by_id(String.t(), pos_integer()) :: {:ok, map() | nil} | {:error, term()}
  def find_by_id(tenant_id, id) do
    sql = @base_select <> " WHERE tenant_id = :1 AND id = :2"
    OracleRepo.query_one(sql, [tenant_id, id])
  end

  @spec find_by_code(String.t(), String.t()) :: {:ok, map() | nil} | {:error, term()}
  def find_by_code(tenant_id, code) do
    sql = @base_select <> " WHERE tenant_id = :1 AND customer_code = :2"
    OracleRepo.query_one(sql, [tenant_id, code])
  end

  @spec list(keyword()) :: {:ok, [map()]} | {:error, term()}
  def list(filters) do
    tenant_id = Keyword.fetch!(filters, :tenant_id)
    page = Keyword.get(filters, :page, 1)
    page_size = Keyword.get(filters, :page_size, 20)
    offset = (page - 1) * page_size

    {where_clauses, params} = build_filters(filters, ["tenant_id = :1"], [tenant_id])

    # Use fixed named placeholders for pagination to avoid fragile dynamic interpolation
    # Note: Oracle supports named binds like :offset, :page_size alongside positional :1, :2
    param_count = length(params)
    offset_placeholder = ":#{param_count + 1}"
    limit_placeholder = ":#{param_count + 2}"

    sql = """
    SELECT * FROM (
      #{@base_select}
      WHERE #{Enum.join(where_clauses, " AND ")}
      ORDER BY name
    )
    OFFSET #{offset_placeholder} ROWS
    FETCH NEXT #{limit_placeholder} ROWS ONLY
    """

    # Build final params list with pagination values appended
    final_params = params ++ [offset, page_size]
    OracleRepo.query(sql, final_params)
  end

  @spec insert(map(), String.t()) :: {:ok, pos_integer()} | {:error, term()}
  def insert(customer, created_by) do
    sql = """
    INSERT INTO customers (
      tenant_id, customer_code, customer_type, name, trade_name,
      tax_id, email, phone, active, created_by
    ) VALUES (
      :1, :2, :3, :4, :5, :6, :7, :8, :9, :10
    )
    RETURNING id INTO :11
    """

    params = [
      customer.tenant_id,
      customer.customer_code,
      customer.customer_type |> Atom.to_string() |> String.upcase(),
      customer.name,
      customer.trade_name,
      customer.tax_id,
      customer.email,
      customer.phone,
      if(customer.active, do: 1, else: 0),
      created_by
    ]

    OracleRepo.execute(sql, params)
  end

  @spec count(String.t(), keyword()) :: {:ok, non_neg_integer()} | {:error, term()}
  def count(tenant_id, filters \\ []) do
    {where_clauses, params} = build_filters(filters, ["tenant_id = :1"], [tenant_id])

    sql = """
    SELECT COUNT(*) AS cnt
    FROM customers
    WHERE #{Enum.join(where_clauses, " AND ")}
    """

    case OracleRepo.query_one(sql, params) do
      {:ok, %{cnt: count}} -> {:ok, count}
      {:error, _} = err -> err
    end
  end

  # Private

  defp build_filters(filters, clauses, params) do
    Enum.reduce(filters, {clauses, params}, fn
      {:active, true}, {c, p} ->
        {c ++ ["active = :#{length(p) + 1}"], p ++ [1]}

      {:active, false}, {c, p} ->
        {c ++ ["active = :#{length(p) + 1}"], p ++ [0]}

      {:search, term}, {c, p} when is_binary(term) ->
        # Escape SQL LIKE wildcards to prevent injection
        # Oracle uses \ as escape character with ESCAPE clause
        escaped_term = term
          |> String.replace("\\", "\\\\")
          |> String.replace("%", "\\%")
          |> String.replace("_", "\\_")
          |> String.upcase()
        like = "%#{escaped_term}%"
        # Add ESCAPE clause to tell Oracle how to interpret escaped chars
        {c ++ ["(UPPER(name) LIKE :#{length(p) + 1} ESCAPE '\\' OR customer_code LIKE :#{length(p) + 2} ESCAPE '\\')"],
         p ++ [like, like]}

      {:customer_type, type}, {c, p} ->
        {c ++ ["customer_type = :#{length(p) + 1}"],
         p ++ [type |> to_string() |> String.upcase()]}

      _, acc ->
        acc
    end)
  end
end
```

---

## Keycloak Authentication

### JWT Validation

```elixir
defmodule GprintEx.Infrastructure.Auth.JwtValidator do
  @moduledoc """
  JWT token validation using HS256 (symmetric key).
  Tokens issued by external auth service (Keycloak via Rust/Actix-Web).

  Expected Claims:
  - user: username/identifier
  - tenant_id: tenant isolation key
  - login_session: session identifier
  """

  require Logger

  @type claims :: %{
    user: String.t(),
    tenant_id: String.t(),
    login_session: String.t(),
    exp: pos_integer(),
    iat: pos_integer()
  }

  @doc "Validate JWT token and extract claims"
  @spec validate(String.t()) :: {:ok, claims()} | {:error, :invalid_token | :expired | :missing_claims}
  def validate(token) when is_binary(token) do
    secret = jwt_secret()

    with {:ok, claims} <- decode_and_verify(token, secret),
         :ok <- validate_expiry(claims),
         :ok <- validate_required_claims(claims) do
      {:ok, normalize_claims(claims)}
    end
  end
  def validate(_), do: {:error, :invalid_token}

  @doc "Extract claims without verification (for logging/debugging only)"
  @spec peek(String.t()) :: {:ok, map()} | {:error, :invalid_token}
  def peek(token) do
    case String.split(token, ".") do
      [_header, payload, _sig] ->
        case Base.url_decode64(payload, padding: false) do
          {:ok, json} -> Jason.decode(json)
          :error -> {:error, :invalid_token}
        end
      _ ->
        {:error, :invalid_token}
    end
  end

  # Private

  defp jwt_secret do
    System.get_env("JWT_SECRET") ||
      raise "JWT_SECRET environment variable is not set"
  end

  defp decode_and_verify(token, secret) do
    case JOSE.JWT.verify_strict(%JOSE.JWK{kty: {:oct, secret}}, ["HS256"], token) do
      {true, %JOSE.JWT{fields: claims}, _jws} ->
        {:ok, claims}
      {false, _, _} ->
        {:error, :invalid_token}
    end
  rescue
    _ -> {:error, :invalid_token}
  end

  defp validate_expiry(%{"exp" => exp}) when is_integer(exp) do
    now = System.system_time(:second)
    if exp > now, do: :ok, else: {:error, :expired}
  end
  defp validate_expiry(_), do: {:error, :expired}

  defp validate_required_claims(claims) do
    required = ["user", "tenant_id", "login_session"]
    missing = Enum.filter(required, &(is_nil(claims[&1]) or claims[&1] == ""))

    if Enum.empty?(missing) do
      :ok
    else
      # Log generic warning (safe for production logs)
      Logger.warning("JWT missing required claim(s)")

      # Detailed claim names only at debug level, controlled by config
      # Set config :gprint_ex, :log_claim_details, true to enable
      if Application.get_env(:gprint_ex, :log_claim_details, false) do
        Logger.debug("JWT validation: missing claims detail", missing: inspect(missing))
      end

      {:error, :missing_claims}
    end
  end

  defp normalize_claims(claims) do
    %{
      user: claims["user"],
      tenant_id: claims["tenant_id"],
      login_session: claims["login_session"],
      exp: claims["exp"],
      iat: claims["iat"]
    }
  end
end
```

### Keycloak Client (OAuth2 Flows)

```elixir
defmodule GprintEx.Infrastructure.Auth.KeycloakClient do
  @moduledoc """
  Keycloak OAuth2 client for token operations.

  Supports:
  - Authorization Code + PKCE flow (recommended)
  - Token refresh
  - Token introspection
  - User info retrieval

  Configuration (environment variables):
  - KEYCLOAK_BASE_URL: e.g., https://keycloak.example.com
  - KEYCLOAK_REALM: e.g., master
  - KEYCLOAK_CLIENT_ID: e.g., gprint-client
  - KEYCLOAK_CLIENT_SECRET: (optional, for confidential clients)
  """

  require Logger

  @type config :: %{
    base_url: String.t(),
    realm: String.t(),
    client_id: String.t(),
    client_secret: String.t() | nil
  }

  @type token_response :: %{
    access_token: String.t(),
    refresh_token: String.t(),
    expires_in: pos_integer(),
    token_type: String.t()
  }

  @type pkce :: %{
    code_verifier: String.t(),
    code_challenge: String.t(),
    code_challenge_method: String.t()
  }

  # Public API

  @doc "Generate PKCE challenge for authorization code flow"
  @spec generate_pkce() :: {:ok, pkce()}
  def generate_pkce do
    verifier_bytes = :crypto.strong_rand_bytes(32)
    code_verifier = Base.url_encode64(verifier_bytes, padding: false)
    code_challenge = :crypto.hash(:sha256, code_verifier) |> Base.url_encode64(padding: false)

    {:ok, %{
      code_verifier: code_verifier,
      code_challenge: code_challenge,
      code_challenge_method: "S256"
    }}
  end

  @doc "Build authorization URL for OAuth2 flow"
  @spec authorization_url(String.t(), String.t(), pkce()) :: String.t()
  def authorization_url(redirect_uri, state, pkce) do
    config = get_config()

    params = URI.encode_query(%{
      "client_id" => config.client_id,
      "response_type" => "code",
      "scope" => "openid profile email",
      "redirect_uri" => redirect_uri,
      "state" => state,
      "code_challenge" => pkce.code_challenge,
      "code_challenge_method" => pkce.code_challenge_method
    })

    "#{authorization_endpoint(config)}?#{params}"
  end

  @doc "Exchange authorization code for tokens"
  @spec exchange_code(String.t(), String.t(), String.t()) ::
          {:ok, token_response()} | {:error, term()}
  def exchange_code(code, redirect_uri, code_verifier) do
    config = get_config()

    body = %{
      "grant_type" => "authorization_code",
      "client_id" => config.client_id,
      "code" => code,
      "redirect_uri" => redirect_uri,
      "code_verifier" => code_verifier
    }
    |> maybe_add_client_secret(config)
    |> URI.encode_query()

    post_token_request(config, body)
  end

  @doc "Refresh access token"
  @spec refresh_token(String.t()) :: {:ok, token_response()} | {:error, term()}
  def refresh_token(refresh_token) do
    config = get_config()

    body = %{
      "grant_type" => "refresh_token",
      "client_id" => config.client_id,
      "refresh_token" => refresh_token
    }
    |> maybe_add_client_secret(config)
    |> URI.encode_query()

    post_token_request(config, body)
  end

  @doc "Introspect token (validate with Keycloak)"
  @spec introspect(String.t()) :: {:ok, map()} | {:error, term()}
  def introspect(token) do
    config = get_config()

    body = %{
      "token" => token,
      "client_id" => config.client_id
    }
    |> maybe_add_client_secret(config)
    |> URI.encode_query()

    case http_post(introspect_endpoint(config), body) do
      {:ok, %{"active" => true} = response} -> {:ok, response}
      {:ok, %{"active" => false}} -> {:error, :token_inactive}
      {:error, _} = err -> err
    end
  end

  @doc "Get user info from Keycloak"
  @spec get_user_info(String.t()) :: {:ok, map()} | {:error, term()}
  def get_user_info(access_token) do
    config = get_config()
    http_get(userinfo_endpoint(config), access_token)
  end

  @doc "Logout (invalidate refresh token)"
  @spec logout(String.t()) :: :ok | {:error, term()}
  def logout(refresh_token) do
    config = get_config()

    body = %{
      "client_id" => config.client_id,
      "refresh_token" => refresh_token
    }
    |> maybe_add_client_secret(config)
    |> URI.encode_query()

    case http_post(logout_endpoint(config), body) do
      {:ok, _} -> :ok
      {:error, _} = err -> err
    end
  end

  # Private

  defp get_config do
    %{
      base_url: System.get_env("KEYCLOAK_BASE_URL") ||
        raise("KEYCLOAK_BASE_URL not set"),
      realm: System.get_env("KEYCLOAK_REALM") ||
        raise("KEYCLOAK_REALM not set"),
      client_id: System.get_env("KEYCLOAK_CLIENT_ID") ||
        raise("KEYCLOAK_CLIENT_ID not set"),
      client_secret: System.get_env("KEYCLOAK_CLIENT_SECRET")
    }
  end

  defp token_endpoint(%{base_url: url, realm: realm}) do
    "#{String.trim_trailing(url, "/")}/realms/#{realm}/protocol/openid-connect/token"
  end

  defp authorization_endpoint(%{base_url: url, realm: realm}) do
    "#{String.trim_trailing(url, "/")}/realms/#{realm}/protocol/openid-connect/auth"
  end

  defp userinfo_endpoint(%{base_url: url, realm: realm}) do
    "#{String.trim_trailing(url, "/")}/realms/#{realm}/protocol/openid-connect/userinfo"
  end

  defp introspect_endpoint(%{base_url: url, realm: realm}) do
    "#{String.trim_trailing(url, "/")}/realms/#{realm}/protocol/openid-connect/token/introspect"
  end

  defp logout_endpoint(%{base_url: url, realm: realm}) do
    "#{String.trim_trailing(url, "/")}/realms/#{realm}/protocol/openid-connect/logout"
  end

  defp maybe_add_client_secret(params, %{client_secret: nil}), do: params
  defp maybe_add_client_secret(params, %{client_secret: ""}), do: params
  defp maybe_add_client_secret(params, %{client_secret: secret}) do
    Map.put(params, "client_secret", secret)
  end

  defp post_token_request(config, body) do
    case http_post(token_endpoint(config), body) do
      {:ok, response} ->
        {:ok, %{
          access_token: response["access_token"],
          refresh_token: response["refresh_token"],
          expires_in: response["expires_in"],
          token_type: response["token_type"]
        }}
      {:error, _} = err ->
        err
    end
  end

  defp http_post(url, body) do
    headers = [{"content-type", "application/x-www-form-urlencoded"}]

    case Finch.build(:post, url, headers, body) |> Finch.request(GprintEx.Finch) do
      {:ok, %{status: 200, body: body}} ->
        Jason.decode(body)
      {:ok, %{status: status, body: body}} ->
        # Log status at error level (safe), full body at debug (may contain tokens)
        Logger.error("Keycloak request failed with status #{status}")
        Logger.debug("Keycloak response body (debug only): #{truncate_body(body)}")
        {:error, {:http_error, status}}
      {:error, reason} ->
        Logger.error("Keycloak request failed: connection error")
        Logger.debug("Keycloak connection error details: #{inspect(reason)}")
        {:error, reason}
    end
  end

  # Truncate/sanitize response body for debug logging to avoid leaking sensitive data
  defp truncate_body(body) when byte_size(body) > 500 do
    String.slice(body, 0, 500) <> "... [truncated]"
  end
  defp truncate_body(body), do: body

  defp http_get(url, access_token) do
    headers = [{"authorization", "Bearer #{access_token}"}]

    case Finch.build(:get, url, headers) |> Finch.request(GprintEx.Finch) do
      {:ok, %{status: 200, body: body}} ->
        Jason.decode(body)
      {:ok, %{status: status, body: body}} ->
        Logger.error("Keycloak userinfo failed: #{status} - #{body}")
        {:error, {:http_error, status}}
      {:error, reason} ->
        {:error, reason}
    end
  end
end
```

### Authentication Plug

```elixir
defmodule GprintExWeb.Plugs.AuthPlug do
  @moduledoc """
  Authentication plug that validates JWT and extracts tenant context.

  Adds to conn.assigns:
  - :current_user (string)
  - :tenant_id (string)
  - :login_session (string)
  - :auth_claims (full claims map)
  """

  import Plug.Conn
  alias GprintEx.Infrastructure.Auth.JwtValidator

  @behaviour Plug

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    with {:ok, token} <- extract_token(conn),
         {:ok, claims} <- JwtValidator.validate(token) do
      conn
      |> assign(:current_user, claims.user)
      |> assign(:tenant_id, claims.tenant_id)
      |> assign(:login_session, claims.login_session)
      |> assign(:auth_claims, claims)
    else
      {:error, reason} ->
        conn
        |> put_status(:unauthorized)
        |> Phoenix.Controller.json(%{
          success: false,
          error: %{
            code: "UNAUTHORIZED",
            message: auth_error_message(reason)
          }
        })
        |> halt()
    end
  end

  # Extract tenant context for use in boundaries
  @doc "Build tenant context from conn.assigns"
  @spec tenant_context(Plug.Conn.t()) :: map()
  def tenant_context(conn) do
    %{
      tenant_id: conn.assigns[:tenant_id],
      user: conn.assigns[:current_user],
      login_session: conn.assigns[:login_session]
    }
  end

  defp extract_token(conn) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> token] -> {:ok, String.trim(token)}
      _ -> {:error, :missing_token}
    end
  end

  defp auth_error_message(:invalid_token), do: "Invalid authentication token"
  defp auth_error_message(:expired), do: "Authentication token has expired"
  defp auth_error_message(:missing_claims), do: "Token missing required claims"
  defp auth_error_message(:missing_token), do: "Authorization header required"
  defp auth_error_message(_), do: "Authentication failed"
end
```

---

## Domain Modules

### Contract Domain

```elixir
defmodule GprintEx.Domain.Contract do
  @moduledoc """
  Contract domain entity with state machine.
  Pure functions - no side effects.
  """

  alias GprintEx.Domain.Types

  @type status :: :draft | :pending | :active | :suspended | :cancelled | :completed
  @type contract_type :: :service | :recurring | :project

  @type t :: %__MODULE__{
    id: pos_integer() | nil,
    tenant_id: Types.tenant_id(),
    contract_number: String.t(),
    contract_type: contract_type(),
    customer_id: pos_integer(),
    start_date: Date.t(),
    end_date: Date.t() | nil,
    duration_months: pos_integer() | nil,
    auto_renew: boolean(),
    total_value: Decimal.t() | nil,
    payment_terms: String.t() | nil,
    billing_cycle: String.t(),
    status: status(),
    signed_at: DateTime.t() | nil,
    signed_by: String.t() | nil,
    notes: String.t() | nil,
    created_at: DateTime.t() | nil,
    updated_at: DateTime.t() | nil
  }

  @enforce_keys [:tenant_id, :contract_number, :customer_id, :start_date]
  defstruct [
    :id,
    :tenant_id,
    :contract_number,
    :contract_type,
    :customer_id,
    :start_date,
    :end_date,
    :duration_months,
    :auto_renew,
    :total_value,
    :payment_terms,
    :billing_cycle,
    :status,
    :signed_at,
    :signed_by,
    :notes,
    :created_at,
    :updated_at
  ]

  # Status transition matrix (from -> [allowed_to])
  @transitions %{
    draft: [:pending, :cancelled],
    pending: [:active, :draft, :cancelled],
    active: [:suspended, :completed, :cancelled],
    suspended: [:active, :cancelled],
    cancelled: [],
    completed: []
  }

  @doc "Create new contract from params"
  @spec new(map()) :: {:ok, t()} | {:error, :validation_failed, [String.t()]}
  def new(params) do
    with {:ok, validated} <- validate(params) do
      {:ok, struct!(__MODULE__, validated)}
    end
  end

  @doc "Build from database row"
  @spec from_row(map()) :: {:ok, t()} | {:error, term()}
  def from_row(row) when is_map(row) do
    {:ok, %__MODULE__{
      id: row[:id],
      tenant_id: row[:tenant_id],
      contract_number: row[:contract_number],
      contract_type: parse_contract_type(row[:contract_type]),
      customer_id: row[:customer_id],
      start_date: row[:start_date],
      end_date: row[:end_date],
      duration_months: row[:duration_months],
      auto_renew: row[:auto_renew] == 1,
      total_value: row[:total_value] && Decimal.new(row[:total_value]),
      payment_terms: row[:payment_terms],
      billing_cycle: row[:billing_cycle] || "MONTHLY",
      status: parse_status(row[:status]),
      signed_at: row[:signed_at],
      signed_by: row[:signed_by],
      notes: row[:notes],
      created_at: row[:created_at],
      updated_at: row[:updated_at]
    }}
  end

  @doc "Check if status transition is allowed"
  @spec can_transition?(t(), status()) :: boolean()
  def can_transition?(%__MODULE__{status: current}, new_status) do
    new_status in Map.get(@transitions, current, [])
  end

  @doc "Transition contract status"
  @spec transition(t(), status()) :: {:ok, t()} | {:error, :invalid_transition}
  def transition(%__MODULE__{} = contract, new_status) do
    if can_transition?(contract, new_status) do
      {:ok, %{contract | status: new_status}}
    else
      {:error, :invalid_transition}
    end
  end

  @doc "Calculate totals from items"
  @spec calculate_totals(t(), [map()]) :: {:ok, t()}
  def calculate_totals(%__MODULE__{} = contract, items) do
    total = items
    |> Enum.map(fn item ->
      qty = Decimal.new(item.quantity || 1)
      price = Decimal.new(item.unit_price || 0)
      discount = Decimal.new(item.discount_pct || 0)
      discount_factor = Decimal.sub(1, Decimal.div(discount, 100))
      Decimal.mult(Decimal.mult(qty, price), discount_factor)
    end)
    |> Enum.reduce(Decimal.new(0), &Decimal.add/2)

    {:ok, %{contract | total_value: total}}
  end

  @doc "Check if contract is active"
  @spec active?(t()) :: boolean()
  def active?(%__MODULE__{status: :active}), do: true
  def active?(_), do: false

  @doc "Check if contract is expired"
  @spec expired?(t()) :: boolean()
  def expired?(%__MODULE__{end_date: nil}), do: false
  def expired?(%__MODULE__{end_date: end_date}) do
    Date.compare(end_date, Date.utc_today()) == :lt
  end

  @doc "Days until expiration (nil if no end_date)"
  @spec days_until_expiry(t()) :: integer() | nil
  def days_until_expiry(%__MODULE__{end_date: nil}), do: nil
  def days_until_expiry(%__MODULE__{end_date: end_date}) do
    Date.diff(end_date, Date.utc_today())
  end

  # Private

  defp validate(params) do
    errors = []
      |> validate_required(params, :tenant_id)
      |> validate_required(params, :contract_number)
      |> validate_required(params, :customer_id)
      |> validate_required(params, :start_date)
      |> validate_date_order(params)

    case errors do
      [] -> {:ok, normalize(params)}
      errors -> {:error, :validation_failed, errors}
    end
  end

  defp validate_required(errors, params, key) do
    if Map.get(params, key) in [nil, ""] do
      ["#{key} is required" | errors]
    else
      errors
    end
  end

  defp validate_date_order(errors, %{start_date: start, end_date: end_date})
       when not is_nil(end_date) do
    if Date.compare(start, end_date) == :gt do
      ["end_date must be after start_date" | errors]
    else
      errors
    end
  end
  defp validate_date_order(errors, _), do: errors

  defp normalize(params) do
    params
    |> Map.put(:status, params[:status] || :draft)
    |> Map.put(:contract_type, parse_contract_type(params[:contract_type]))
    |> Map.put(:auto_renew, params[:auto_renew] || false)
    |> Map.put(:billing_cycle, params[:billing_cycle] || "MONTHLY")
  end

  defp parse_status("DRAFT"), do: :draft
  defp parse_status("PENDING"), do: :pending
  defp parse_status("ACTIVE"), do: :active
  defp parse_status("SUSPENDED"), do: :suspended
  defp parse_status("CANCELLED"), do: :cancelled
  defp parse_status("COMPLETED"), do: :completed
  defp parse_status(s) when is_atom(s), do: s
  defp parse_status(_), do: :draft

  defp parse_contract_type("SERVICE"), do: :service
  defp parse_contract_type("RECURRING"), do: :recurring
  defp parse_contract_type("PROJECT"), do: :project
  defp parse_contract_type(t) when is_atom(t), do: t
  defp parse_contract_type(_), do: :service
end
```

### CLM Workflow (State Machine)

```elixir
defmodule GprintEx.Domain.Workflow do
  @moduledoc """
  CLM Workflow state machine.
  Handles approval, review, and signature workflows.
  """

  @type workflow_type :: :approval | :review | :signature | :renewal
  @type workflow_status :: :pending | :in_progress | :completed | :cancelled
  @type step_status :: :pending | :in_progress | :approved | :rejected | :completed | :skipped

  @type step :: %{
    step_number: pos_integer(),
    step_type: :approval | :review | :signature | :notification,
    step_name: String.t(),
    assigned_to: String.t() | nil,
    assigned_to_role: String.t() | nil,
    status: step_status(),
    due_date: DateTime.t() | nil,
    action_taken: String.t() | nil,
    action_at: DateTime.t() | nil
  }

  @type t :: %__MODULE__{
    workflow_id: String.t() | nil,
    contract_id: String.t(),
    workflow_type: workflow_type(),
    status: workflow_status(),
    current_step: pos_integer(),
    total_steps: pos_integer(),
    steps: [step()],
    started_at: DateTime.t() | nil,
    completed_at: DateTime.t() | nil
  }

  defstruct [
    :workflow_id,
    :contract_id,
    :workflow_type,
    :status,
    :current_step,
    :total_steps,
    :steps,
    :started_at,
    :completed_at
  ]

  @doc "Create a new workflow with steps"
  @spec create(String.t(), workflow_type(), [map()]) :: {:ok, t()}
  def create(contract_id, workflow_type, step_definitions) do
    steps = step_definitions
    |> Enum.with_index(1)
    |> Enum.map(fn {step_def, idx} ->
      %{
        step_number: idx,
        step_type: step_def.type,
        step_name: step_def.name,
        assigned_to: step_def[:assigned_to],
        assigned_to_role: step_def[:role],
        status: :pending,
        due_date: step_def[:due_date],
        action_taken: nil,
        action_at: nil
      }
    end)

    {:ok, %__MODULE__{
      contract_id: contract_id,
      workflow_type: workflow_type,
      status: :pending,
      current_step: 1,
      total_steps: length(steps),
      steps: steps,
      started_at: nil,
      completed_at: nil
    }}
  end

  @doc "Start the workflow"
  @spec start(t()) :: {:ok, t()} | {:error, :already_started}
  def start(%__MODULE__{status: :pending} = wf) do
    {:ok, %{wf |
      status: :in_progress,
      started_at: DateTime.utc_now(),
      steps: update_step_status(wf.steps, 1, :in_progress)
    }}
  end
  def start(_), do: {:error, :already_started}

  @doc "Complete current step and advance"
  @spec complete_step(t(), pos_integer(), atom(), String.t()) ::
          {:ok, t()} | {:error, :invalid_step | :workflow_not_active}
  def complete_step(%__MODULE__{status: :in_progress, current_step: current} = wf, step_num, action, _user)
      when step_num == current do
    updated_steps = update_step_action(wf.steps, step_num, action)
    next_step = current + 1

    if next_step > wf.total_steps do
      # Workflow complete
      {:ok, %{wf |
        status: :completed,
        current_step: wf.total_steps,
        steps: updated_steps,
        completed_at: DateTime.utc_now()
      }}
    else
      # Advance to next step
      {:ok, %{wf |
        current_step: next_step,
        steps: updated_steps |> update_step_status(next_step, :in_progress)
      }}
    end
  end
  def complete_step(%__MODULE__{status: :in_progress}, _, _, _), do: {:error, :invalid_step}
  def complete_step(_, _, _, _), do: {:error, :workflow_not_active}

  @doc "Reject current step and cancel workflow"
  @spec reject_step(t(), pos_integer(), String.t()) :: {:ok, t()} | {:error, term()}
  def reject_step(%__MODULE__{status: :in_progress, current_step: current} = wf, step_num, _reason)
      when step_num == current do
    {:ok, %{wf |
      status: :cancelled,
      steps: update_step_action(wf.steps, step_num, :rejected)
    }}
  end
  def reject_step(_, _, _), do: {:error, :invalid_step}

  @doc "Get current step"
  @spec current_step(t()) :: step() | nil
  def current_step(%__MODULE__{steps: steps, current_step: num}) do
    Enum.find(steps, &(&1.step_number == num))
  end

  @doc "Check if workflow is complete"
  @spec completed?(t()) :: boolean()
  def completed?(%__MODULE__{status: :completed}), do: true
  def completed?(_), do: false

  # Private

  defp update_step_status(steps, step_num, new_status) do
    Enum.map(steps, fn step ->
      if step.step_number == step_num do
        %{step | status: new_status}
      else
        step
      end
    end)
  end

  defp update_step_action(steps, step_num, action) do
    Enum.map(steps, fn step ->
      if step.step_number == step_num do
        %{step | status: :completed, action_taken: to_string(action), action_at: DateTime.utc_now()}
      else
        step
      end
    end)
  end
end
```

---

## Error Handling

### Structured Errors

```elixir
defmodule GprintEx.Error do
  @moduledoc """
  Structured error types.
  All errors follow a consistent pattern.
  """

  @type error_code :: atom()
  @type t :: {:error, error_code()} | {:error, error_code(), term()}

  # Domain errors
  def not_found(entity), do: {:error, :not_found, entity}
  def validation_failed(errors), do: {:error, :validation_failed, errors}
  def invalid_transition(from, to), do: {:error, :invalid_transition, {from, to}}
  def unauthorized, do: {:error, :unauthorized}
  def forbidden, do: {:error, :forbidden}

  # Infrastructure errors
  def database_error(reason), do: {:error, :database_error, reason}
  def external_service_error(service, reason), do: {:error, :external_service_error, {service, reason}}

  @doc "Convert error to HTTP status and response"
  @spec to_http(t()) :: {integer(), map()}
  def to_http({:error, :not_found, entity}) do
    {404, %{code: "NOT_FOUND", message: "#{entity} not found"}}
  end

  def to_http({:error, :validation_failed, errors}) do
    {422, %{code: "VALIDATION_ERROR", message: "Validation failed", details: errors}}
  end

  def to_http({:error, :invalid_transition, {from, to}}) do
    {409, %{code: "INVALID_STATE_TRANSITION", message: "Cannot transition from #{from} to #{to}"}}
  end

  def to_http({:error, :unauthorized}) do
    {401, %{code: "UNAUTHORIZED", message: "Authentication required"}}
  end

  def to_http({:error, :forbidden}) do
    {403, %{code: "FORBIDDEN", message: "Access denied"}}
  end

  def to_http({:error, :database_error, _reason}) do
    {500, %{code: "DATABASE_ERROR", message: "Database operation failed"}}
  end

  def to_http({:error, code}) when is_atom(code) do
    {500, %{code: String.upcase(to_string(code)), message: "Operation failed"}}
  end

  def to_http(_) do
    {500, %{code: "INTERNAL_ERROR", message: "An unexpected error occurred"}}
  end
end
```

---

## API Specification

### Response Format

```elixir
# Success responses
%{
  success: true,
  data: %{...}
}

# Paginated responses
%{
  success: true,
  data: [%{...}, ...],
  pagination: %{
    page: 1,
    page_size: 20,
    total_items: 150,
    total_pages: 8
  }
}

# Error responses
%{
  success: false,
  error: %{
    code: "VALIDATION_ERROR",
    message: "Validation failed",
    details: ["name is required", "email format invalid"]
  }
}
```

### Endpoints

| Method | Path | Description |
|--------|------|-------------|
| GET | /api/v1/health | Health check |
| GET | /api/v1/ready | Readiness check |
| **Customers** | | |
| GET | /api/v1/customers | List customers |
| POST | /api/v1/customers | Create customer |
| GET | /api/v1/customers/:id | Get customer |
| PUT | /api/v1/customers/:id | Update customer |
| DELETE | /api/v1/customers/:id | Deactivate customer |
| **Contracts** | | |
| GET | /api/v1/contracts | List contracts |
| POST | /api/v1/contracts | Create contract |
| GET | /api/v1/contracts/:id | Get contract |
| PUT | /api/v1/contracts/:id | Update contract |
| POST | /api/v1/contracts/:id/transition | Transition status |
| **Generation** | | |
| POST | /api/v1/contracts/:id/generate | Generate document |
| GET | /api/v1/contracts/:id/generated | List generated docs |
| GET | /api/v1/generated/:id | Get generated doc |
| **Print Jobs** | | |
| POST | /api/v1/contracts/:id/print | Queue print job |
| GET | /api/v1/print-jobs | List print jobs |
| GET | /api/v1/print-jobs/:id | Get print job status |
| **CLM** | | |
| GET | /api/v1/clm/parties | List parties |
| POST | /api/v1/clm/parties | Create party |
| GET | /api/v1/clm/contracts | List CLM contracts |
| POST | /api/v1/clm/contracts | Create CLM contract |
| GET | /api/v1/clm/contracts/:id/workflow | Get workflow status |
| POST | /api/v1/clm/contracts/:id/workflow/step | Complete workflow step |

---

## Security

### Secret Management

> **⚠️ CRITICAL: Never store secrets in plain text or version control**

#### Secrets to Protect

| Secret | Description | Risk if Exposed |
|--------|-------------|------------------|
| `JWT_SECRET` | Token signing key | Full authentication bypass |
| `ORACLE_PASSWORD` | Database credentials | Complete data breach |
| `KEYCLOAK_CLIENT_SECRET` | OAuth2 client secret | Token forgery |
| `SECRET_KEY_BASE` | Phoenix session encryption | Session hijacking |
| Oracle Wallet (`cwallet.sso`) | Database SSL certificate | Database impersonation |

#### Required Protections

1. **Never commit secrets to git**
   ```bash
   # Add to .gitignore
   .envrc
   .env
   .env.local
   priv/wallet/cwallet.sso
   priv/wallet/ewallet.p12
   ```

2. **Use placeholder templates**
   ```bash
   # .envrc.example (safe to commit)
   export JWT_SECRET="<generate-with-mix-phx.gen.secret-64>"
   export ORACLE_PASSWORD="<your-oracle-password>"
   export KEYCLOAK_CLIENT_SECRET="<your-client-secret>"
   ```

3. **Generate strong secrets**
   ```bash
   # Generate 64-byte JWT secret
   mix phx.gen.secret 64

   # Or using OpenSSL
   openssl rand -base64 64
   ```

4. **Restrict wallet file permissions**
   ```bash
   chmod 600 priv/wallet/*
   chown $(whoami) priv/wallet/*
   ```

#### Production Secret Management

Use a dedicated secrets manager instead of environment files:

| Platform | Recommended Solution |
|----------|---------------------|
| AWS | AWS Secrets Manager, Parameter Store |
| Azure | Azure Key Vault |
| GCP | Google Secret Manager |
| Kubernetes | Kubernetes Secrets (with encryption at rest) |
| HashiCorp | Vault |
| Self-hosted | SOPS, Age, or sealed-secrets |

#### Secret Rotation Policy

| Secret | Rotation Frequency | Procedure |
|--------|-------------------|------------|
| `JWT_SECRET` | Quarterly or on compromise | Update auth service, invalidate existing tokens |
| `ORACLE_PASSWORD` | Quarterly | Coordinate with DBA, update running instances |
| `KEYCLOAK_CLIENT_SECRET` | Annually | Rotate in Keycloak admin, update config |
| Oracle Wallet | On certificate expiry | Download new wallet from Oracle Cloud Console |

#### Runtime Configuration

```elixir
# config/runtime.exs - fetch secrets at runtime, not compile time
config :gprint_ex, :jwt,
  secret: System.fetch_env!("JWT_SECRET")  # Fails fast if missing

# For Kubernetes/Vault integration:
config :gprint_ex, :jwt,
  secret: VaultClient.read_secret("gprint/jwt_secret")
```

---

## Configuration

### Environment Variables

```bash
# Application
PORT=4000
PHX_HOST=localhost
SECRET_KEY_BASE=<64_byte_hex>

# Oracle Database (Wallet Authentication)
ORACLE_WALLET_PATH=/app/priv/wallet
ORACLE_TNS_ALIAS=mydb_high
ORACLE_USER=ADMIN
ORACLE_PASSWORD=<password>

# Authentication
JWT_SECRET=<shared_secret_with_auth_service>

# Keycloak (for token operations)
KEYCLOAK_BASE_URL=https://keycloak.example.com
KEYCLOAK_REALM=master
KEYCLOAK_CLIENT_ID=gprint-client
KEYCLOAK_CLIENT_SECRET=<optional_for_confidential>
```

### Runtime Configuration

```elixir
# config/runtime.exs
import Config

if config_env() == :prod do
  config :gprint_ex, GprintExWeb.Endpoint,
    url: [host: System.get_env("PHX_HOST") || "localhost"],
    http: [port: String.to_integer(System.get_env("PORT") || "4000")],
    secret_key_base: System.fetch_env!("SECRET_KEY_BASE")

  config :gprint_ex, GprintEx.Infrastructure.Repo.OracleRepo,
    wallet_path: System.fetch_env!("ORACLE_WALLET_PATH"),
    tns_alias: System.fetch_env!("ORACLE_TNS_ALIAS"),
    user: System.fetch_env!("ORACLE_USER"),
    password: System.fetch_env!("ORACLE_PASSWORD"),
    pool_size: String.to_integer(System.get_env("ORACLE_POOL_SIZE") || "10")

  config :gprint_ex, :jwt,
    secret: System.fetch_env!("JWT_SECRET")

  config :gprint_ex, :keycloak,
    base_url: System.fetch_env!("KEYCLOAK_BASE_URL"),
    realm: System.fetch_env!("KEYCLOAK_REALM"),
    client_id: System.fetch_env!("KEYCLOAK_CLIENT_ID"),
    client_secret: System.get_env("KEYCLOAK_CLIENT_SECRET")
end
```

---

## Testing Strategy

### Test Structure

```
test/
├── domain/                    # Pure function tests (fast, no deps)
│   ├── customer_test.exs
│   ├── contract_test.exs
│   └── workflow_test.exs
│
├── boundaries/                # Integration tests (with DB)
│   ├── customers_test.exs
│   └── contracts_test.exs
│
├── infrastructure/            # External integration tests
│   ├── repo/
│   │   └── oracle_repo_test.exs
│   └── auth/
│       └── jwt_validator_test.exs
│
└── gprint_ex_web/
    ├── controllers/
    │   ├── customer_controller_test.exs
    │   └── contract_controller_test.exs
    └── plugs/
        └── auth_plug_test.exs
```

### Test Example (Pure Domain)

```elixir
defmodule GprintEx.Domain.ContractTest do
  use ExUnit.Case, async: true  # Pure functions = parallel safe

  alias GprintEx.Domain.Contract

  describe "new/1" do
    test "creates valid contract" do
      params = %{
        tenant_id: "tenant-1",
        contract_number: "CTR-001",
        customer_id: 1,
        start_date: ~D[2026-01-01]
      }

      assert {:ok, %Contract{} = contract} = Contract.new(params)
      assert contract.status == :draft
      assert contract.contract_type == :service
    end

    test "returns error for missing required fields" do
      assert {:error, :validation_failed, errors} = Contract.new(%{})
      assert "tenant_id is required" in errors
    end
  end

  describe "transition/2" do
    test "allows valid transitions" do
      contract = %Contract{status: :draft, tenant_id: "t", contract_number: "c", customer_id: 1, start_date: ~D[2026-01-01]}

      assert {:ok, %{status: :pending}} = Contract.transition(contract, :pending)
    end

    test "rejects invalid transitions" do
      contract = %Contract{status: :completed, tenant_id: "t", contract_number: "c", customer_id: 1, start_date: ~D[2026-01-01]}

      assert {:error, :invalid_transition} = Contract.transition(contract, :draft)
    end
  end
end
```

---

## Makefile Reference

The following Makefile targets are used in this project. For the full Makefile, see [elixir-makefile-reference.mk](elixir-makefile-reference.mk).

### Core Development Targets

| Target | Description | Environment |
|--------|-------------|-------------|
| `make deps` | Install all Mix dependencies (`mix deps.get`) | Any |
| `make compile` | Compile project with warnings as errors | `MIX_ENV=dev` |
| `make dev` | Start Phoenix server with hot reload | `MIX_ENV=dev`, requires Oracle wallet |
| `make run` | Run application without hot reload (`mix run --no-halt`) | `MIX_ENV=dev` |
| `make iex` | Start IEx shell with application loaded | `MIX_ENV=dev` |

### Testing Targets

| Target | Description | Environment |
|--------|-------------|-------------|
| `make test` | Run all tests | `MIX_ENV=test` |
| `make test.unit` | Run only domain/pure function tests | `MIX_ENV=test` |
| `make test.integration` | Run tests requiring database | `MIX_ENV=test`, requires Oracle |
| `make test.cover` | Generate HTML coverage report | `MIX_ENV=test` |

### Code Quality Targets

| Target | Description | Environment |
|--------|-------------|-------------|
| `make format` | Format all Elixir code | Any |
| `make format.check` | Check if code is formatted (CI) | Any |
| `make lint` | Run Credo linter with strict mode | Any |
| `make dialyzer` | Run Dialyzer type checker | Any |
| `make check` | Run format.check + lint + test | `MIX_ENV=test` |

### Database Targets

| Target | Description | Environment |
|--------|-------------|-------------|
| `make db.setup` | Run migrations on Oracle | Requires Oracle wallet |
| `make db.migrate` | Run pending migrations | Requires Oracle wallet |
| `make oracle.check` | Verify Oracle wallet and connectivity | Requires Oracle wallet |

### Infrastructure Targets

| Target | Description | Environment |
|--------|-------------|-------------|
| `make keycloak.check` | Verify Keycloak connectivity | Requires `KEYCLOAK_BASE_URL` |
| `make env.check` | Verify all required env vars are set | Any |

### Cleanup Targets

| Target | Description |
|--------|-------------|
| `make clean` | Remove `_build`, `deps`, `doc`, `cover` |
| `make clean.deps` | Remove only `deps` and `_build` |
| `make clean.all` | Full cleanup including `.elixir_ls`, `.dialyzer` |

### Environment Requirements

Targets that interact with Oracle require:
- `ORACLE_WALLET_PATH` - Path to wallet directory
- `ORACLE_TNS_ALIAS` - TNS alias (e.g., `mydb_high`)
- `ORACLE_USER` / `ORACLE_PASSWORD` - Database credentials
- `TNS_ADMIN` - Set automatically by Makefile to wallet path

Targets that interact with Keycloak require:
- `KEYCLOAK_BASE_URL` - Keycloak server URL
- `KEYCLOAK_REALM` - Realm name
- `KEYCLOAK_CLIENT_ID` - Client ID

---

## Quick Start

```bash
# Clone and setup
git clone git@github.com:zlovtnik/gprint_ex.git
cd gprint_ex

# Copy environment template
cp .envrc.example .envrc
# Edit .envrc with your Oracle wallet and Keycloak settings

# Install dependencies
make deps

# Setup Oracle wallet (copy files to priv/wallet/)
# Ensure tnsnames.ora and sqlnet.ora are configured

# Run tests
make test

# Start development server
make dev

# Open http://localhost:4000/api/v1/health
```

---

## Schema Reference

### Core Tables (001_initial_schema.sql)

| Table | Description |
|-------|-------------|
| `customers` | Customer entities (individual/company) |
| `services` | Service catalog |
| `contracts` | Service contracts |
| `contract_items` | Contract line items |
| `contract_history` | Audit trail |
| `contract_print_jobs` | Print queue |

### Generation Tables (002_contract_generation_pkg.sql)

| Table | Description |
|-------|-------------|
| `contract_templates` | Document templates |
| `generated_contracts` | Generated document cache |
| `contract_generation_log` | Generation audit |

### CLM Tables (003_clm_schema.sql)

| Table | Description |
|-------|-------------|
| `clm_parties` | Organizations/Individuals |
| `clm_contract_types` | Contract type definitions |
| `clm_contracts` | CLM contracts |
| `clm_contract_versions` | Version history |
| `clm_documents` | Contract documents |
| `clm_templates` | Document templates |
| `clm_workflow_instances` | Active workflows |
| `clm_workflow_steps` | Workflow step status |
| `clm_obligations` | Contract obligations |
| `clm_obligation_updates` | Obligation tracking |
| `clm_audit_trail` | Immutable audit log |

---

*Last Updated: January 2026*
