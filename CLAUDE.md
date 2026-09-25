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

## Current phase: one-week spike

Goal: something an agent can use against a real running app, measured against an
eval set of real diagnostic questions (see below).

### In scope

- **Tables:** `processes`, `supervisors`, `ets_tables`, `applications`.
- **Windowed sampling:** `sample(window_ms)`, which collects twice and computes deltas
  (e.g. `reductions_delta`, `memory_delta`) before inserting.
- **Term summarization:** by default, return term *shapes* (type, size, key set,
  truncated preview), never full large terms. Drill-down is opt-in and size-capped.
- **Policy struct** with all capability tiers defined. Only `:observe` is implemented;
  every other tier returns a clear "not enabled" error.
- **Two front doors:**
  - a CLI (mix task / remote-shell entry point)
  - an MCP endpoint

### Out of scope (for now)

- Tracing (planned next tier: budgeted, session-scoped, using OTP 27+ trace sessions)
- Eval, `:sys.get_state`, any mutation
- History / continuous collection / persistence (that is closer to a telemetry product)
- Joining with static program data (xref / call graph); planned later
- Redaction beyond basic `Inspect` respect (planned; don't design it out)

## Architecture decisions

### Per-query snapshots, no sync

SQLite is a throwaway query engine, **not a replica** of node state:

1. Receive the SQL query.
2. Determine which tables (and ideally which columns) it references.
3. Collect only that data, right now.
4. Load it into a fresh in-memory SQLite (`exqlite`), run the query, and discard the database.

The BEAM remains the source of truth, so there is nothing to keep in sync.

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

- Collect only the referenced tables and columns. `Process.info/2` with an explicit key list
  avoids full `Process.info/1`.
- Push simple filters/limits into collection where feasible.
- Hard caps on rows collected and on result size, with an explicit truncation flag in results.
- The snapshot is **not atomic**, since processes change during the walk. Document this.

### Capability tiers (the model is designed now, only Observe is implemented)

| Tier     | Examples                                    | Gate                  |
|----------|---------------------------------------------|-----------------------|
| observe  | table queries, sampled stats                | allowed by policy     |
| trace    | budgeted trace sessions                     | allowed with budgets  |
| evaluate | code eval, `:sys.get_state`                 | sandboxed / dev only  |
| mutate   | kill, `:sys.replace_state`, hot code load   | human approval        |

Policies compose by **intersection** (environment ∩ session ∩ request budget), following the
same model as Airlock. Every query should be audit-loggable.

## Initial table sketch (refine against the eval set)

- `processes`: node, pid, registered_name, initial_call, current_function,
  message_queue_len, memory, reductions, status, links_count, monitors_count,
  ancestors (as text/JSON), `$initial_call` from the process dictionary when available,
  label (OTP 27+ `Process.set_label`), plus `*_delta` columns when sampled
- `supervisors`: node, pid, name, strategy, child_id, child_pid, child_type,
  child_module, restart counts if obtainable
- `ets_tables`: node, name/id, owner_pid, type, protection, size, memory
- `applications`: node, name, vsn, description, running

Reuse ideas and collection code from `recon` (e.g. `proc_window`) and `observer_cli`
instead of reinventing them.

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

## Working conventions

- Write tests with a real test supervision tree and spawned processes. Don't mock the runtime.
- Include a small demo app (or `test/support` fixture) with deliberately misbehaving
  processes (mailbox growth, restart loop, hot GenServer) to exercise the eval set.
- All outputs are agent-facing: structured, bounded, with explicit truncation markers.
