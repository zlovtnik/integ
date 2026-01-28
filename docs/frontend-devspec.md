# GprintEx Integration Dashboard - Frontend Development Specification

> **Stack**: Svelte 5 + SvelteKit + TypeScript + Bun  
> **Purpose**: Integration management dashboard for CLM ETL pipelines, message routing, and monitoring

---

## 1. Overview

### 1.1 Project Goals
Build a reactive, type-safe dashboard for managing and monitoring the GprintEx integration layer:
- ETL pipeline management (sessions, staging, validation, promotion)
- Message routing configuration (dynamic routes, recipient lists)
- Real-time integration monitoring (message channels, aggregations)
- Contract/Customer data import workflows

### 1.2 Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                    SvelteKit Frontend                        │
│  ┌─────────────┐  ┌─────────────┐  ┌─────────────────────┐  │
│  │   Routes    │  │   Stores    │  │    Components       │  │
│  │  /dashboard │  │  etlStore   │  │  DataTable          │  │
│  │  /etl/*     │  │  routeStore │  │  PipelineStatus     │  │
│  │  /routes/*  │  │  messageStore│ │  RouteEditor        │  │
│  │  /messages/*│  │  authStore  │  │  MessageInspector   │  │
│  └─────────────┘  └─────────────┘  └─────────────────────┘  │
└─────────────────────────────────────────────────────────────┘
                              │
                              ▼ HTTP/WebSocket
┌─────────────────────────────────────────────────────────────┐
│              GprintEx Elixir Backend (port 4000)            │
│  /api/etl/*  /api/routes/*  /api/messages/*  /api/ws        │
└─────────────────────────────────────────────────────────────┘
```

---

## 2. Technology Stack

| Layer | Technology | Version | Purpose |
|-------|------------|---------|---------|
| Runtime | Bun | 1.x | Package manager, bundler, runtime |
| Framework | SvelteKit | 2.x | Full-stack Svelte framework |
| UI Framework | Svelte | 5.x | Reactive components with runes |
| Language | TypeScript | 5.x | Type safety |
| Styling | Tailwind CSS | 3.x | Utility-first CSS |
| Icons | Lucide Svelte | latest | Icon library |
| Charts | Chart.js + svelte-chartjs | latest | Metrics visualization |
| Tables | TanStack Table | 8.x | Data tables with sorting/filtering |
| Forms | Superforms + Zod | latest | Form validation |
| State | Svelte 5 Runes | native | $state, $derived, $effect |
| HTTP | Native fetch | native | API calls |
| WebSocket | Native WebSocket | native | Real-time updates |

---

## 3. Project Structure

```
frontend/
├── bun.lockb
├── package.json
├── svelte.config.js
├── vite.config.ts
├── tsconfig.json
├── tailwind.config.js
├── postcss.config.js
│
├── src/
│   ├── app.html
│   ├── app.css                 # Tailwind imports
│   ├── app.d.ts                # Global type declarations
│   │
│   ├── lib/
│   │   ├── api/
│   │   │   ├── client.ts       # Base API client with auth
│   │   │   ├── etl.ts          # ETL API functions
│   │   │   ├── routes.ts       # Routing API functions
│   │   │   ├── messages.ts     # Message/channel API functions
│   │   │   └── types.ts        # API response types
│   │   │
│   │   ├── stores/
│   │   │   ├── auth.svelte.ts  # Auth state (Keycloak token)
│   │   │   ├── etl.svelte.ts   # ETL sessions/pipelines
│   │   │   ├── routes.svelte.ts# Dynamic routing rules
│   │   │   └── messages.svelte.ts # Message channels
│   │   │
│   │   ├── components/
│   │   │   ├── ui/             # Base UI components
│   │   │   │   ├── Button.svelte
│   │   │   │   ├── Card.svelte
│   │   │   │   ├── Modal.svelte
│   │   │   │   ├── Badge.svelte
│   │   │   │   ├── Alert.svelte
│   │   │   │   └── Spinner.svelte
│   │   │   │
│   │   │   ├── data/           # Data display components
│   │   │   │   ├── DataTable.svelte
│   │   │   │   ├── JsonViewer.svelte
│   │   │   │   └── StatusBadge.svelte
│   │   │   │
│   │   │   ├── etl/            # ETL-specific components
│   │   │   │   ├── SessionList.svelte
│   │   │   │   ├── SessionDetail.svelte
│   │   │   │   ├── PipelineBuilder.svelte
│   │   │   │   ├── StagingTable.svelte
│   │   │   │   ├── ValidationResults.svelte
│   │   │   │   └── ImportWizard.svelte
│   │   │   │
│   │   │   ├── routes/         # Routing components
│   │   │   │   ├── RouteList.svelte
│   │   │   │   ├── RouteEditor.svelte
│   │   │   │   ├── PatternBuilder.svelte
│   │   │   │   └── RouteStats.svelte
│   │   │   │
│   │   │   ├── messages/       # Messaging components
│   │   │   │   ├── ChannelList.svelte
│   │   │   │   ├── MessageInspector.svelte
│   │   │   │   ├── AggregationView.svelte
│   │   │   │   └── DeadLetterQueue.svelte
│   │   │   │
│   │   │   └── layout/         # Layout components
│   │   │       ├── Sidebar.svelte
│   │   │       ├── Header.svelte
│   │   │       ├── Breadcrumb.svelte
│   │   │       └── ThemeToggle.svelte
│   │   │
│   │   ├── utils/
│   │   │   ├── format.ts       # Date/number formatting
│   │   │   ├── validation.ts   # Zod schemas
│   │   │   └── websocket.ts    # WebSocket manager
│   │   │
│   │   └── types/
│   │       ├── etl.ts          # ETL domain types
│   │       ├── routes.ts       # Routing domain types
│   │       ├── messages.ts     # Message domain types
│   │       └── common.ts       # Shared types
│   │
│   └── routes/
│       ├── +layout.svelte      # Root layout with sidebar
│       ├── +layout.server.ts   # Auth check
│       ├── +page.svelte        # Dashboard home
│       │
│       ├── etl/
│       │   ├── +page.svelte            # ETL overview
│       │   ├── sessions/
│       │   │   ├── +page.svelte        # Session list
│       │   │   └── [id]/
│       │   │       └── +page.svelte    # Session detail
│       │   ├── import/
│       │   │   └── +page.svelte        # Import wizard
│       │   └── pipelines/
│       │       └── +page.svelte        # Pipeline builder
│       │
│       ├── routes/
│       │   ├── +page.svelte            # Route list
│       │   ├── [id]/
│       │   │   └── +page.svelte        # Route detail/edit
│       │   └── new/
│       │       └── +page.svelte        # Create route
│       │
│       ├── messages/
│       │   ├── +page.svelte            # Message overview
│       │   ├── channels/
│       │   │   └── +page.svelte        # Channel list
│       │   ├── aggregations/
│       │   │   └── +page.svelte        # Aggregation view
│       │   └── dead-letter/
│       │       └── +page.svelte        # DLQ management
│       │
│       └── settings/
│           └── +page.svelte            # App settings
│
├── static/
│   └── favicon.png
│
└── tests/
    ├── unit/
    └── e2e/
```

---

## 4. Core Types (TypeScript)

### 4.1 ETL Types

```typescript
// src/lib/types/etl.ts

export type SessionStatus = 
  | 'created' 
  | 'loading' 
  | 'transforming' 
  | 'validating' 
  | 'promoting' 
  | 'completed' 
  | 'failed' 
  | 'rolled_back';

export interface ETLSession {
  session_id: string;
  tenant_id: string;
  source_system: string;
  status: SessionStatus;
  total_records: number;
  valid_records: number;
  error_records: number;
  promoted_records: number;
  created_at: string;
  completed_at: string | null;
}

export interface StagingRecord {
  seq_num: number;
  session_id: string;
  tenant_id: string;
  entity_type: 'CONTRACT' | 'CUSTOMER';
  entity_id: string;
  raw_data: Record<string, unknown>;
  transformed_data: Record<string, unknown> | null;
  validation_status: 'pending' | 'valid' | 'invalid';
  error_message: string | null;
  created_at: string;
}

export interface ValidationResult {
  record_id: number;
  issue_type: 'VALID' | 'MISSING_FIELD' | 'PARSE_ERROR' | 'CONSTRAINT';
  message: string;
  context: string | null;
}

export interface ImportConfig {
  file: File;
  format: 'csv' | 'json' | 'jsonl' | 'xml';
  entity_type: 'CONTRACT' | 'CUSTOMER';
  source_system: string;
  encoding: 'utf8' | 'latin1' | 'utf16';
  field_mapping: Record<string, string>;
}
```

### 4.2 Routing Types

```typescript
// src/lib/types/routes.ts

export type PatternType = 'exact' | 'glob' | 'regex' | 'function';

export interface RoutePattern {
  type: PatternType;
  value: string;
}

export interface RouteEntry {
  id: string;
  pattern: RoutePattern;
  destination: string;
  priority: number;
  active: boolean;
  metadata: Record<string, unknown>;
  created_at: string;
  updated_at: string;
}

export interface RouteStats {
  total_routes: number;
  active_routes: number;
  routed_count: number;
  unrouted_count: number;
  route_hits: Record<string, number>;
}
```

### 4.3 Message Types

```typescript
// src/lib/types/messages.ts

export interface Message {
  id: string;
  message_type: string;
  payload: Record<string, unknown>;
  metadata: Record<string, unknown>;
  priority: 'low' | 'normal' | 'high' | 'critical';
  timestamp: string;
  correlation_id: string | null;
}

export interface Channel {
  name: string;
  queue_size: number;
  subscriber_count: number;
  stats: {
    published: number;
    delivered: number;
    dropped: number;
  };
}

export interface Aggregation {
  id: number;
  correlation_id: string;
  aggregation_key: string;
  expected_count: number | null;
  current_count: number;
  status: 'pending' | 'complete' | 'timeout';
  started_at: string;
  timeout_at: string;
}

export interface DeadLetterMessage {
  id: number;
  original_message_id: string;
  message_payload: string;
  failure_reason: string;
  retry_count: number;
  moved_at: string;
}
```

---

## 5. API Client

### 5.1 Base Client

```typescript
// src/lib/api/client.ts

import { authStore } from '$lib/stores/auth.svelte';

const API_BASE = import.meta.env.VITE_API_URL || 'http://localhost:4000/api';

export interface ApiError {
  status: number;
  message: string;
  details?: unknown;
}

export async function apiRequest<T>(
  endpoint: string,
  options: RequestInit = {}
): Promise<T> {
  const token = authStore.token;
  
  const response = await fetch(`${API_BASE}${endpoint}`, {
    ...options,
    headers: {
      'Content-Type': 'application/json',
      ...(token ? { Authorization: `Bearer ${token}` } : {}),
      ...options.headers,
    },
  });

  if (!response.ok) {
    const error: ApiError = {
      status: response.status,
      message: response.statusText,
    };
    try {
      error.details = await response.json();
    } catch {}
    throw error;
  }

  return response.json();
}

export const api = {
  get: <T>(endpoint: string) => apiRequest<T>(endpoint),
  
  post: <T>(endpoint: string, data: unknown) =>
    apiRequest<T>(endpoint, {
      method: 'POST',
      body: JSON.stringify(data),
    }),
    
  put: <T>(endpoint: string, data: unknown) =>
    apiRequest<T>(endpoint, {
      method: 'PUT',
      body: JSON.stringify(data),
    }),
    
  delete: <T>(endpoint: string) =>
    apiRequest<T>(endpoint, { method: 'DELETE' }),
};
```

### 5.2 ETL API

```typescript
// src/lib/api/etl.ts

import { api } from './client';
import type { ETLSession, StagingRecord, ValidationResult } from '$lib/types/etl';

interface ApiResponse<T> {
  success: boolean;
  data: T;
}

export const etlApi = {
  // Sessions
  listSessions: (params?: { status?: string; limit?: number }) =>
    api.get<ApiResponse<ETLSession[]>>(`/etl/sessions?${new URLSearchParams(params as any)}`),
    
  getSession: (id: string) =>
    api.get<ApiResponse<ETLSession>>(`/etl/sessions/${id}`),
    
  createSession: (data: { tenant_id: string; source_system: string }) =>
    api.post<ApiResponse<{ session_id: string }>>('/etl/sessions', data),
    
  // Staging
  getStagingRecords: (sessionId: string, params?: { status?: string; page?: number }) =>
    api.get<ApiResponse<StagingRecord[]>>(
      `/etl/sessions/${sessionId}/staging?${new URLSearchParams(params as any)}`
    ),
    
  // Validation
  validateSession: (sessionId: string) =>
    api.post<ApiResponse<ValidationResult[]>>(`/etl/sessions/${sessionId}/validate`, {}),
    
  // Promotion
  promoteSession: (sessionId: string) =>
    api.post<ApiResponse<{ promoted_count: number }>>(`/etl/sessions/${sessionId}/promote`, {}),
    
  // Rollback
  rollbackSession: (sessionId: string) =>
    api.post<ApiResponse<void>>(`/etl/sessions/${sessionId}/rollback`, {}),
    
  // Import
  uploadFile: async (sessionId: string, file: File, config: Record<string, unknown>) => {
    const formData = new FormData();
    formData.append('file', file);
    formData.append('config', JSON.stringify(config));
    
    const response = await fetch(`/api/etl/sessions/${sessionId}/upload`, {
      method: 'POST',
      body: formData,
    });
    return response.json();
  },
};
```

---

## 6. Svelte 5 Stores (Runes)

### 6.1 ETL Store

```typescript
// src/lib/stores/etl.svelte.ts

import { etlApi } from '$lib/api/etl';
import type { ETLSession, StagingRecord } from '$lib/types/etl';

class ETLStore {
  sessions = $state<ETLSession[]>([]);
  currentSession = $state<ETLSession | null>(null);
  stagingRecords = $state<StagingRecord[]>([]);
  loading = $state(false);
  error = $state<string | null>(null);

  // Derived
  activeSessions = $derived(
    this.sessions.filter(s => !['completed', 'failed', 'rolled_back'].includes(s.status))
  );
  
  sessionStats = $derived({
    total: this.sessions.length,
    active: this.activeSessions.length,
    completed: this.sessions.filter(s => s.status === 'completed').length,
    failed: this.sessions.filter(s => s.status === 'failed').length,
  });

  async loadSessions() {
    this.loading = true;
    this.error = null;
    try {
      const response = await etlApi.listSessions();
      this.sessions = response.data;
    } catch (e) {
      this.error = e instanceof Error ? e.message : 'Failed to load sessions';
    } finally {
      this.loading = false;
    }
  }

  async loadSession(id: string) {
    this.loading = true;
    try {
      const response = await etlApi.getSession(id);
      this.currentSession = response.data;
    } catch (e) {
      this.error = e instanceof Error ? e.message : 'Failed to load session';
    } finally {
      this.loading = false;
    }
  }

  async createSession(tenantId: string, sourceSystem: string) {
    const response = await etlApi.createSession({ tenant_id: tenantId, source_system: sourceSystem });
    await this.loadSessions();
    return response.data.session_id;
  }

  async validateSession(sessionId: string) {
    return etlApi.validateSession(sessionId);
  }

  async promoteSession(sessionId: string) {
    const result = await etlApi.promoteSession(sessionId);
    await this.loadSession(sessionId);
    return result;
  }
}

export const etlStore = new ETLStore();
```

---

## 7. Component Examples

### 7.1 Session List Component

```svelte
<!-- src/lib/components/etl/SessionList.svelte -->
<script lang="ts">
  import { etlStore } from '$lib/stores/etl.svelte';
  import StatusBadge from '$lib/components/data/StatusBadge.svelte';
  import { formatDistanceToNow } from '$lib/utils/format';
  import { RefreshCw, Eye, Play, RotateCcw } from 'lucide-svelte';

  let { onSelect }: { onSelect?: (id: string) => void } = $props();

  $effect(() => {
    etlStore.loadSessions();
  });
</script>

<div class="bg-white rounded-lg shadow">
  <div class="px-4 py-3 border-b flex justify-between items-center">
    <h2 class="text-lg font-semibold">ETL Sessions</h2>
    <button
      onclick={() => etlStore.loadSessions()}
      class="p-2 hover:bg-gray-100 rounded"
      disabled={etlStore.loading}
    >
      <RefreshCw class="w-4 h-4 {etlStore.loading ? 'animate-spin' : ''}" />
    </button>
  </div>

  {#if etlStore.error}
    <div class="p-4 text-red-600 bg-red-50">{etlStore.error}</div>
  {/if}

  <div class="divide-y">
    {#each etlStore.sessions as session (session.session_id)}
      <div class="p-4 hover:bg-gray-50 flex items-center justify-between">
        <div class="flex-1">
          <div class="flex items-center gap-2">
            <span class="font-mono text-sm">{session.session_id}</span>
            <StatusBadge status={session.status} />
          </div>
          <div class="text-sm text-gray-500 mt-1">
            {session.source_system} • {session.total_records} records
            • {formatDistanceToNow(session.created_at)}
          </div>
        </div>
        <div class="flex gap-2">
          <button
            onclick={() => onSelect?.(session.session_id)}
            class="p-2 hover:bg-gray-200 rounded"
            title="View details"
          >
            <Eye class="w-4 h-4" />
          </button>
        </div>
      </div>
    {:else}
      <div class="p-8 text-center text-gray-500">
        No sessions found
      </div>
    {/each}
  </div>
</div>
```

### 7.2 Status Badge Component

```svelte
<!-- src/lib/components/data/StatusBadge.svelte -->
<script lang="ts">
  import type { SessionStatus } from '$lib/types/etl';

  let { status }: { status: SessionStatus | string } = $props();

  const colors: Record<string, string> = {
    created: 'bg-gray-100 text-gray-700',
    loading: 'bg-blue-100 text-blue-700',
    transforming: 'bg-purple-100 text-purple-700',
    validating: 'bg-yellow-100 text-yellow-700',
    promoting: 'bg-indigo-100 text-indigo-700',
    completed: 'bg-green-100 text-green-700',
    failed: 'bg-red-100 text-red-700',
    rolled_back: 'bg-orange-100 text-orange-700',
    pending: 'bg-gray-100 text-gray-700',
    valid: 'bg-green-100 text-green-700',
    invalid: 'bg-red-100 text-red-700',
  };
</script>

<span class="px-2 py-0.5 text-xs font-medium rounded-full {colors[status] || 'bg-gray-100'}">
  {status}
</span>
```

---

## 8. API Endpoints Required (Backend)

The frontend expects these endpoints from the Elixir backend:

### 8.1 ETL Endpoints

| Method | Endpoint | Description |
|--------|----------|-------------|
| GET | `/api/etl/sessions` | List all sessions |
| POST | `/api/etl/sessions` | Create new session |
| GET | `/api/etl/sessions/:id` | Get session details |
| GET | `/api/etl/sessions/:id/staging` | Get staging records |
| POST | `/api/etl/sessions/:id/upload` | Upload file to session |
| POST | `/api/etl/sessions/:id/transform` | Transform staging data |
| POST | `/api/etl/sessions/:id/validate` | Validate staging data |
| POST | `/api/etl/sessions/:id/promote` | Promote to production |
| POST | `/api/etl/sessions/:id/rollback` | Rollback session |

### 8.2 Routing Endpoints

| Method | Endpoint | Description |
|--------|----------|-------------|
| GET | `/api/routes` | List all routes |
| POST | `/api/routes` | Create new route |
| GET | `/api/routes/:id` | Get route details |
| PUT | `/api/routes/:id` | Update route |
| DELETE | `/api/routes/:id` | Delete route |
| POST | `/api/routes/:id/toggle` | Enable/disable route |
| GET | `/api/routes/stats` | Get routing statistics |

### 8.3 Message Endpoints

| Method | Endpoint | Description |
|--------|----------|-------------|
| GET | `/api/messages/channels` | List channels |
| GET | `/api/messages/channels/:name` | Get channel details |
| GET | `/api/messages/aggregations` | List aggregations |
| GET | `/api/messages/dead-letter` | List DLQ messages |
| POST | `/api/messages/dead-letter/:id/retry` | Retry DLQ message |

### 8.4 WebSocket

| Endpoint | Events |
|----------|--------|
| `/api/ws` | `session:updated`, `message:routed`, `validation:complete` |

---

## 9. Development Setup

### 9.1 Initialize Project

```bash
# Create SvelteKit project with Bun
cd /Users/rcs/git/fire/integ
mkdir frontend && cd frontend

bun create svelte@latest . --template skeleton --types typescript

# Install dependencies
bun add -d tailwindcss postcss autoprefixer
bun add -d @sveltejs/adapter-static
bun add lucide-svelte chart.js svelte-chartjs
bun add @tanstack/svelte-table
bun add sveltekit-superforms zod

# Initialize Tailwind
bunx tailwindcss init -p
```

### 9.2 Development Commands

```bash
# Start dev server (connects to Elixir backend on :4000)
bun run dev

# Build for production
bun run build

# Preview production build
bun run preview

# Type check
bun run check

# Run tests
bun test
```

### 9.3 Environment Variables

```env
# frontend/.env
VITE_API_URL=http://localhost:4000/api
VITE_WS_URL=ws://localhost:4000/api/ws
VITE_KEYCLOAK_URL=http://localhost:8080
VITE_KEYCLOAK_REALM=gprint
VITE_KEYCLOAK_CLIENT_ID=gprint-frontend
```

---

## 10. Integration with Backend

### 10.1 CORS Configuration (Elixir)

Update `lib/gprint_ex_web/endpoint.ex`:

```elixir
plug CORSPlug,
  origin: ["http://localhost:5173", "http://localhost:4173"],
  methods: ["GET", "POST", "PUT", "DELETE", "OPTIONS"],
  headers: ["Authorization", "Content-Type"]
```

### 10.2 Proxy for Development

In `vite.config.ts`:

```typescript
export default defineConfig({
  plugins: [sveltekit()],
  server: {
    proxy: {
      '/api': {
        target: 'http://localhost:4000',
        changeOrigin: true,
      },
    },
  },
});
```

---

## 11. Testing Strategy

| Type | Tool | Location |
|------|------|----------|
| Unit | Vitest | `tests/unit/` |
| Component | Testing Library | `tests/unit/components/` |
| E2E | Playwright | `tests/e2e/` |
| API Mocks | MSW | `tests/mocks/` |

---

## 12. Deployment

### 12.1 Static Build

Build as static site and serve from Elixir:

```bash
bun run build
# Output: frontend/build/

# Copy to Elixir priv/static/app
cp -r build/* ../priv/static/app/
```

### 12.2 Docker

```dockerfile
FROM oven/bun:1 as builder
WORKDIR /app
COPY package.json bun.lockb ./
RUN bun install --frozen-lockfile
COPY . .
RUN bun run build

FROM nginx:alpine
COPY --from=builder /app/build /usr/share/nginx/html
COPY nginx.conf /etc/nginx/nginx.conf
EXPOSE 80
```

---

## 13. Milestones

| Phase | Features | Timeline |
|-------|----------|----------|
| **Phase 1** | Project setup, auth, basic layout, ETL session list | Week 1 |
| **Phase 2** | ETL detail views, import wizard, validation UI | Week 2 |
| **Phase 3** | Route management, pattern builder | Week 3 |
| **Phase 4** | Message monitoring, WebSocket integration | Week 4 |
| **Phase 5** | Charts, stats dashboard, polish | Week 5 |

---

## 14. Next Steps

1. Initialize frontend project with `bun create svelte`
2. Set up Tailwind CSS
3. Create base layout and routing
4. Implement auth store with Keycloak integration
5. Build ETL session list as first feature
6. Add backend API endpoints as needed
