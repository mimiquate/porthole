# Porthole

Hex package: `porthole` · Root module: `Porthole` · Mix task prefix: `mix porthole.*`

The name: a porthole is a window you can look through but not pass through, just as this layer is
read-only. Porthole is a sibling to Airlock (Mimiquate's agent sandboxing library):
Airlock controls what agents can *do*, Porthole controls what they can *see*.

## What this is

A read-only query layer that lets coding agents inspect a live BEAM system with SQL.
Motivated by José Valim's "Evolving programming languages in the AI era"
(dashbit.co/blog/evolving-ai-era, Sep 2026): the Erlang VM already exposes processes,
supervisors, ETS, ports, etc.; the missing piece is exposing that *safely* and
*composably* to agents, instead of human-oriented tools like debuggers and `:observer`.

Agents write queries such as "processes with mailbox > 500 grouped by initial_call"
instead of calling many narrow tools.

Mimiquate open-source project. Code should be idiomatic, well-typed (specs), documented,
and production-minded.

## Current phase: spike

Goal: something an agent can use against a real running app, measured against an
eval set of real diagnostic questions (see below).

**Guiding principle: keep it as simple as possible.** The first version over-engineered
column pruning, custom sampling and inter-node encoding; it was cut roughly in half with no
loss on the eval set. Prefer fewer columns, fewer options and less code. Add complexity only
when a real question needs it.

### In scope (implemented)

- **Tables:** `processes`, `supervisors`, `ets_tables`, `ports`, `applications`, `system`.
- **Windowed sampling:** the `window_ms` option snapshots tables that declare delta
  columns at the start of the window, collects again at the end, and adds
  `<column>_delta` columns (e.g. `reductions_delta`, `memory_delta`, `size_delta`).
- **Term summarization:** arbitrary terms (labels, child ids) are rendered with `inspect/2`
  when small, or as a JSON *shape* (type, size, keys, truncated preview), always within
  256 bytes. Drill-down is not implemented.
- **Policy struct** with all capability tiers defined. Only `:observe` is implemented;
  every other tier returns a clear "not enabled" error.
- **Front doors:**
  - CLI: `mix porthole.query` (local, `--demo`, or `--connect` to a running node)
  - remote shell / IEx: `Porthole.print/2`
  - MCP over stdio: `mix porthole.mcp`, a single `query` tool whose description embeds the schema
    (for development, next to the agent)
  - MCP over HTTP: `mix porthole.server` / `Porthole.Server` (`Porthole.MCP.Plug` on Bandit), the
    production sidecar, with per-client bearer tokens (`mix porthole.gen.token`, only SHA-256
    hashes in config), per-token policies, Origin checks, and structured audit (`Porthole.Audit`)
- **Guides** for the community in `guides/`: use cases, query cookbook, team setup.

### Out of scope (for now)

- Tracing (planned next tier: budgeted, session-scoped, using OTP 27+ trace sessions)
- Eval, `:sys.get_state`, any mutation
- History / continuous collection / persistence (that is closer to a telemetry product)
- Joining with static program data (xref / call graph); planned later
- Redaction beyond basic `Inspect` respect (planned; don't design it out)
- Column pruning and filter pushdown (tried and removed for simplicity; revisit only if
  collection cost shows up on large nodes, and only for the expensive items like `:binary`)
- Phase 2 of the production roadmap: packaged sidecar (release/image), node discovery,
  collector version check, `doctor`, deployment recipes, client snippets, in-app dev
  endpoint. Phase 3: large-node benchmarks, filter pushdown if needed, redaction, package
  split, security review, real-incident evals. Phase 1 (HTTP transport, tokens, per-token
  policy, audit, rate/concurrency limits, on-node deadlines, low priority, byte caps, CI) is
  done
- Crash reasons (would need a logger-fed ring buffer, i.e. state; needs a decision) and
  mailbox contents (`process_info(:messages)` copies the whole queue; risky)

## Architecture decisions

### Per-query snapshots, no sync

SQLite is a throwaway query engine, **not a replica** of node state:

1. Receive the SQL query.
2. Determine which tables it mentions (a word match on table names; no SQL parsing).
3. Collect those tables, with all their columns, right now.
4. Load them into a fresh in-memory SQLite (`exqlite`), run the query, and discard the database.

The BEAM remains the source of truth, so there is nothing to keep in sync. SQLite is there for
the query language (joins, GROUP BY, subqueries, recursive CTEs), which is what makes queries
composable; it is not a storage layer.

Read-only is enforced by a SQLite authorizer (installed after loading) that denies writes,
`ATTACH`, `PRAGMA` and schema changes. Don't add SQL-level validation on top of it.

Per-query collection was chosen over periodic sampling on purpose: no cost when nobody is
looking, answers are exact "now", no state. History is out of scope.

### Layering

- **Core:** a pure-Elixir collector API (functions returning rows/maps). Stable, and
  usable without SQL.
- **Query layer:** SQL over in-memory SQLite, built on the core. It could be swapped later
  (e.g. for Datalog) without touching the collectors.
- **Front doors:** CLI + MCP, which are thin.

### Multi-node

- The querying node fans out collection with `:erpc.multicall`.
- Every row gets a `node` column; all nodes' rows go into one in-memory DB.
- Only the querying node needs `exqlite`. Other nodes need only the pure-Elixir collector.
- **Sidecar deployment:** the query layer can run on a separate node that joins the cluster,
  so production nodes carry no NIF. Keep the collector free of NIF deps to preserve this.

### Cost controls (important)

- Collect only the referenced tables. `Process.info/2` uses an explicit item list, and
  process dictionary entries are read key by key (`{:dictionary, key}`), never whole.
- Nothing runs between queries.
- `:erpc` does **not** stop remote work when the caller times out (verified). Collection
  therefore runs in a low-priority worker with a deadline enforced on the observed node
  itself, and the tables leave out the collecting processes (`self()` and `$callers`).
  Never rely on the caller's timeout alone to bound work on a production node.
- Hard caps (policy): rows and bytes collected per table per node, rows returned,
  query/collection timeout, window length; cells are cut at 1 KB. Every cut sets `truncated`
  and adds a human-readable entry to `notes` saying which limit cut it.
- Load limits (policy, enforced by `Porthole.Limiter`): `max_concurrent` queries on the
  querying node across all clients, and `queries_per_minute` per identified client (the
  `:client` query option; MCP passes the token id or "stdio"; library calls without a client
  are only concurrency-limited). Rejections are `:busy` / `:rate_limited` errors with a retry
  hint; rejected queries don't count. The limiter monitors query processes so crashes free
  slots, and it only starts where SQLite is available: observed nodes run no Porthole
  processes (tested).
- The snapshot is **not atomic**, since processes change during the walk. Document this.

### Trust boundary (important)

Porthole guarantees that *its tool* is read-only. The node running queries holds the
distribution cookie, which grants full control of the cluster (there is no read-only cookie).
In production the HTTP sidecar keeps the cookie inside the cluster and agents only get a URL
and a token. That holds only if Porthole is the agent's only route into production and the
sidecar host is protected; the stdio transport puts the cookie next to the agent and is for
development. Never present Porthole as a security boundary on its own.

HTTP requests are checked before any work: bearer token (401), `Origin` allowlist (403,
DNS-rebinding protection), 1 MB body cap. The server refuses to start without tokens and
binds to 127.0.0.1 by default. Plug and Bandit are optional deps; modules using them are
wrapped in `if Code.ensure_loaded?(...)`.

### Versions

Elixir 1.18+ (built-in `JSON`) and OTP 27+ (`Process.info/2` with `{:dictionary, key}` fails
on OTP 25; OTP 26 is untested). CI (`.github/workflows/ci.yml`) runs 1.18/27, 1.19/28 and
1.20/29. The collector checks the OTP version per query and reports old nodes in `errors`;
never add checks that could crash a host application at boot.

### Capability tiers (the model is designed now, only Observe is implemented)

| Tier     | Examples                                    | Gate                  |
|----------|---------------------------------------------|-----------------------|
| observe  | table queries, sampled stats                | allowed by policy     |
| trace    | budgeted trace sessions                     | allowed with budgets  |
| evaluate | code eval, `:sys.get_state`                 | sandboxed / dev only  |
| mutate   | kill, `:sys.replace_state`, hot code load   | human approval        |

Policies compose by **intersection** (environment ∩ session ∩ request budget), following the
same model as Airlock. Every query should be audit-loggable: queries emit
`[:porthole, :query, *]` telemetry, and the MCP server logs every query to stderr.

## Tables

Each table is a module in `lib/porthole/tables/` implementing `Porthole.Table` (`name`,
`description`, `columns`, `key`, `deltas`, `collect/1`) and listed in `Porthole.Table.all/0`.
Every table also gets a `node` column at load time. Column docs live in the modules and flow
into the MCP tool description, so keep them short and useful to an agent.

- `processes`: pid, registered_name, initial_call, current_function, waiting_on, label,
  application, ancestors, status, message_queue_len, memory, binary_memory, reductions,
  links/monitors/monitored_by counts. Deltas: reductions, memory, message_queue_len,
  binary_memory.
  - `initial_call` is translated like `:proc_lib.translate_initial_call/1` (via
    `$initial_call`); supervisors' `{supervisor, Mod, 1}` renders as `Mod.init/1`.
  - `waiting_on`: a process blocked in a gen call or `Task.await` monitors its target, and
    that is its most recent (last) monitor. Relies on undocumented VM ordering; best effort.
  - `application` is derived from the group leader (application master).
- `supervisors`: one row per child: pid, name, module, child_id, child_pid, child_status,
  child_type. Found via `$initial_call` (covers Supervisor, DynamicSupervisor,
  Task.Supervisor); `which_children` with a 1s timeout, `unreachable` if no answer. No
  strategy or restart counts: those need `:sys.get_state` (evaluate tier). Restart loops
  are detected via the supervisor's `reductions_delta`.
- `ets_tables`: id, name, owner, type, protection, size, memory. Deltas: size, memory.
  Metadata only, never contents.
- `ports`: port, name, owner, local/remote address, os_pid, input, output, queue_size,
  memory. Deltas: input, output, queue_size. Only inet-driver sockets (`gen_tcp`/`gen_udp`),
  not the NIF-based `:socket` module.
- `applications`: name, vsn, description, running.
- `system`: one row per node: memory by category, process/atom/port/ETS counts vs limits,
  run_queue, schedulers, reductions, uptime. The starting point of most investigations.
  Scheduler utilization is deliberately absent (it requires flipping a VM flag).

## Eval set (replace with real incidents from client work)

Each question is an acceptance test. Compare an agent that has this tool against one with only
shell/remote console access.

1. Which GenServer is serializing calls and driving p99 latency up?
2. What's leaking memory, and on which node?
3. Which supervisor is restart-looping, and what are its children?
4. Which processes have the largest mailboxes, grouped by what spawned them?
5. Which ETS tables are growing fastest over a 10s window, and who owns them?
6. Which processes burn the most reductions over a 5s window?
7. Are there orphaned processes (no links, no monitors, not supervised)?
8. Which application's processes account for most memory?

Added beyond the original set: is any VM limit getting close (`system`)? Who is leaking
sockets (`ports`)? Is there a deadlock (recursive CTE over `waiting_on`)?

All of these are answered with one query each in `test/porthole/eval_test.exs` against
`Porthole.Demo`.

## Working conventions

- Write tests with a real test supervision tree and spawned processes. Don't mock the runtime.
  Multi-node tests use `:peer` nodes without `exqlite` on their code path, which proves
  observed nodes only need the collector.
- `Porthole.Demo` (`test/support/porthole/demo.ex`, also compiled in dev for
  `mix porthole.query --demo`) starts `:shop`, a small OTP application with planted problems,
  one per eval question: serializing server, leak, restart loop, stuck mailbox, growing ETS,
  hot loop, orphan, socket leak, deadlocked pair. Add one when adding an eval question.
  Start it with `Porthole.Demo.start/1` (unlinked, so it survives `iex -S mix run -e`), stop
  it with `stop/0`.
- **Keep the demo blind.** Everything visible at runtime (module, registered, table and
  application names, child ids, messages) must look like an ordinary app: no "demo",
  "leak", "slow", "crash" or similar. The first agent eval recognized the old descriptive
  names and read the answers off them. The answer key lives only in the moduledoc.
- Every ```sql block in `guides/` is executed by `test/porthole/guides_test.exs` against the
  demo (`-- window_ms: N` in a block turns on sampling). When the schema changes, the guides
  must still pass. Check new guide queries return sensible rows, not just that they run.
- All outputs are agent-facing: structured, bounded, with explicit truncation markers.
- Before finishing: `mix format`, `mix compile --warnings-as-errors`, `mix test`, and
  `mix docs` without warnings.
