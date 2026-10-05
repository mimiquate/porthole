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
  - In-app development endpoint: `forward "/porthole", Porthole.MCP.Plug, auth: :localhost`
    (loopback-only, rejects proxied requests and browsers; never in production)
  - `mix porthole.doctor` (`Porthole.Doctor`): per-node reachability, Elixir, OTP,
    latency and a real collection, with what to fix; `GET /healthz` on the HTTP plug
- **`mix porthole.fly.up APP` / `fly.down APP`** (`Porthole.Fly`): a zero-change production
  trial on Fly.io. `up` reads the running release's cookie and distribution settings from
  `/proc/<beam>/environ` over `fly ssh console` (works for generated per-build cookies too),
  imports it as the sidecar's secret via stdin (never printed, never in argv), generates a
  token, deploys the published image (`ghcr.io/mimiquate/porthole-sidecar:latest`; `--image`
  to override, `--build` to build from the checkout), checks through a temporary
  `fly proxy` that nodes are observed, and prints the tunnel + `claude mcp add` commands.
  `down` destroys only apps that are Porthole sidecars (`PORTHOLE_PORT` in their config).
  `PORTHOLE_FLY` overrides the `fly` executable (tests use a fake). Verified with a
  Docker-backed fake `fly` and on real Fly (2026-10-02: ex-tools, and my-poll, which has no
  Porthole dependency and a build-generated cookie). `up` marks its sidecars
  (`PORTHOLE_TRIAL` env) and both commands only act on marked ones, so a team's permanent
  sidecar is never touched; `down` asks for the name to be typed.
- **`mix porthole.k8s.up DEPLOYMENT` / `k8s.down`** (`Porthole.Kube`; shared code in
  `Porthole.Trial`): the same trial on Kubernetes. Creates a Deployment, a Secret and a
  headless Service selecting the app's pods (the sidecar finds them by DNS), all labelled
  `porthole.mimiquate.com/trial=<sidecar>`; `down` deletes by that label. When the pod spec
  takes `RELEASE_COOKIE` from a Secret (`secretKeyRef` or `envFrom`), the sidecar references
  it and the cookie is never read (the inspection script runs with `nocookie`). Requires long
  names with the pod IP as host; hostname-based names (StatefulSets) are refused for now.
  Checks `auth can-i` first; waits until it sees as many nodes as ready pods; a token
  fingerprint annotation on the pod template rolls the sidecar when tokens change (pods read
  Secrets only at start). Verified on kind 2026-10-05 (Secret cookie, build-time cookie,
  NetworkPolicy deny and allow, permanent-sidecar refusal, the permanent manifest).
  Lesson: containerd as configured by kind sets the open-files limit to ~1e9, and the BEAM
  sizes its port table from it, reserving GBs: OOMKilled at start under a memory limit. The
  sidecar image sets `ERL_MAX_PORTS=65536`.
- **Sidecar image**: `.github/workflows/sidecar-image.yml` publishes `sidecar/Dockerfile` to
  `ghcr.io/mimiquate/porthole-sidecar` for amd64 and arm64: `:latest` and `:sha-…` from
  `main`, `:X.Y.Z` from `vX.Y.Z` tags. The package must be public for Fly and clusters to
  pull it without credentials.
- **`sidecar/`**: a separate Mix project (depends on the library by path) that packages the
  production sidecar as a release and Docker image, configured only by env vars
  (`PortholeSidecar.Config`), tracking the cluster every 5s (seeds, their peers, DNS
  discovery; `PortholeSidecar.Cluster`) and passing `nodes: &Cluster.nodes/0` so each query
  resolves the current node set. Keep it thin: logic belongs in the library.
- **Guides** for the community in `guides/`: use cases, query cookbook, team setup.

### Out of scope (for now)

- Tracing (planned next tier: budgeted, session-scoped, using OTP 27+ trace sessions)
- Eval, `:sys.get_state`, any mutation
- History / continuous collection / persistence (that is closer to a telemetry product)
- Joining with static program data (xref / call graph); planned later
- Redaction beyond basic `Inspect` respect (planned; don't design it out)
- Column pruning and filter pushdown (tried and removed for simplicity). Measured again
  2026-10-02: all 15 `process_info` items for 100k processes take 144 ms compiled, and no
  item dominates (each costly one is 60–90 ms alone, mostly shared overhead), so pruning
  items would save little. The cost is in evaluation (below), not in the items.
- Phase 2 of the production roadmap, remaining: Kubernetes is verified on kind only, not on
  a managed cluster (guides/deploy-kubernetes.md says so). Fly.io is verified in production (2026-10-01, elixir_toolbox /
  ex-tools, guides/deploy-fly.md): discovery from `ex-tools.internal` with image-id node
  names, IPv6, `fly proxy`, a real agent querying. First-deploy lesson: a cookie copied by
  hand differed from the app's ("Invalid challenge reply" in the app's logs); Fly secret
  digests are value-based, so equal digests confirm equal cookies. IPv6 distribution itself is
  verified locally (2026-09-30: node named with an uncompressed IPv6 address, found via
  host and via DNS). IPv6 lessons: pass parsed addresses to `:erl_epmd.names/1` (an IPv6
  string is taken for a hostname and fails with nxdomain), try both compressed and
  uncompressed spellings of IPv6 node names, and prefer the DNS address family of the
  sidecar's own distribution; more client snippets. Sidecar and app are upgraded
  independently since collection by evaluation (no Porthole on observed nodes); an OTP 27
  sidecar observes OTP 27–29 apps and vice versa (tested 2026-10-01), so one prebuilt image
  can serve everyone. The Docker image is
  verified (2026-09-28): compose with an app on long names and a fixed cookie, discovery
  from DNS_CLUSTER_QUERY, scaling 1→2→1, wrong cookie, missing config, non-root user.
  The builder image tag must exist on Docker Hub (hexpm/elixir tags carry a Debian date). Phase 3: large-node benchmarks, filter pushdown if needed, redaction, package
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

### Multi-node: collection by evaluation

- **Observed nodes need no Porthole** (decision 2026-10-01): only Elixir and OTP 27+.
  This is what makes a production trial possible without changing or redeploying the app,
  and lets sidecar and app be upgraded independently.
- Each table is two halves: `gather/1` names a function in `Porthole.Gather` that reads raw
  data on the node, and `shape/1` turns it into rows on the querying node (shaping, term
  rendering and deltas never run on production nodes).
- `Porthole.Remote` sends the *compiled* code of those functions (Erlang abstract code) and
  the node evaluates it with `:erl_eval` via `:erpc`. Nothing is loaded on the node. The
  querying node calls `Porthole.Gather` directly for itself.
- **Rules for `Porthole.Gather`, enforced at build time** by `Porthole.Gather.Check`
  (`@after_compile`; a violation fails the build): call only OTP modules plus
  `Enum.reduce/3` (what `for` compiles to; the node may run another Elixir version), and
  no calls to sibling functions (an evaluated fun cannot see them; use anonymous helpers).
  The check also stores each function's abstract code in `Porthole.Gather.Code` at build
  time, because releases strip debug info.
- Trust model: the only code evaluated on nodes is Porthole's own, fixed at build time and
  read-only. Agents send SQL, never code; SQL runs on the querying node. Evaluating needs
  nothing beyond the cookie the querying node already holds.
- Pids, ports and refs are rendered as their own node sees them (`Remote.pid/1`).
- Cost: evaluation dominates. `erl_eval` pays for every interpreted step and variable
  binding, so gather functions do as little per item as possible: one call and one match
  per process, `:lists` functions (compiled on the node) where possible, and tuples rather
  than keyword lists. `Remote.run` passes bindings as a map: with the default orddict,
  binding many variables per process made evaluation 2–3× slower (verified on OTP 27–29).
  100k processes (2026-10-02): `processes` gather 1.3 s evaluated vs 153 ms compiled;
  end to end ~3.8 s, result 19 MB (was ~5.4 s and 47 MB with a function mapped over each
  item). Things that were slower: `:lists.zipwith` over `process_info` (extra list work).
- Every row gets a `node` column; all nodes' rows go into one in-memory DB.
- Only the querying node needs `exqlite`. Keep `Porthole.Gather` free of NIF deps.
- **Decision (2026-09-28): production means a separate sidecar, with a fixed cookie.**
  Running Porthole embedded in the app (plug in the prod router) was considered and set aside:
  it avoids cookie handling, but an overloaded or down app takes Porthole with it (exactly
  when it is needed) and it puts a NIF and a port on production nodes. The cost of the
  sidecar is that the app must use a fixed cookie shared as a secret (`RELEASE_COOKIE`), since
  `mix release` otherwise generates one per build. The team-setup guide makes this step 1 of
  the production setup; don't document the sidecar as if teams already had a shared cookie.
  The sidecar finds nodes by *where* the app runs (DNS / hosts + epmd names), never by
  requiring node names up front.

### Cost controls (important)

- Collect only the referenced tables. `Process.info/2` uses an explicit item list, and
  process dictionary entries are read key by key (`{:dictionary, key}`), never whole.
- Nothing runs between queries.
- `:erpc` does **not** stop remote work when the caller times out (verified). Collection
  therefore runs in a low-priority worker with a deadline enforced on the observed node
  itself, and the tables leave out the collecting processes (`self()` and `$callers`).
  Never rely on the caller's timeout alone to bound work on a production node.
- Hard caps (policy): rows collected per table per node (on the node), bytes loaded per
  table per node (on the querying node), rows returned,
  query/collection timeout, window length; cells are cut at 1 KB. Every cut sets `truncated`
  and adds a human-readable entry to `notes` saying which limit cut it.
- Load limits (policy, enforced by `Porthole.Limiter`): `max_concurrent` queries on the
  querying node across all clients, and `queries_per_minute` per identified client (the
  `:client` query option; MCP passes the token id or "stdio"; library calls without a client
  are only concurrency-limited). Rejections are `:busy` / `:rate_limited` errors with a retry
  hint; rejected queries don't count. The limiter monitors query processes so crashes free
  slots, and it only starts where SQLite is available: observed nodes run no Porthole
  processes (tested), and don't need Porthole at all.
- The snapshot is **not atomic**, since processes change during the walk. Document this.
- Measured under CPU saturation (2026-10-02, laptop, 8 schedulers, 16 busy loops): the
  `processes` walk is ~30–50× slower than idle at low priority (10k processes: 0.34 s →
  16 s; 100k: 4.3 s → ~120 s), so it times out at the default 10 s on saturated nodes;
  `system` and `ets_tables` stay in milliseconds. Collecting did not measurably affect app
  latency. Normal priority was tried and rejected: only 3–5× faster (100k still 20–38 s)
  and it caused 180–300 ms stalls in app processes. Reduce work instead of raising
  priority.

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

Elixir 1.18+ (built-in `JSON`) and OTP 27+ where queries run. Observed nodes: Elixir (any
recent version) and OTP 27+ (`Process.info/2` with `{:dictionary, key}` fails on OTP 25;
OTP 26 is untested). CI (`.github/workflows/ci.yml`) runs 1.18/27, 1.19/28 and 1.20/29.
The gather code checks the OTP version per query and reports old nodes, and nodes without
Elixir, in `errors`; never add checks that could crash a host application at boot.

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
`description`, `columns`, `key`, `deltas`, `gather/1`, `shape/1`) and listed in
`Porthole.Table.all/0`. Its node-side half is a function in `Porthole.Gather`.
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
  child_type. Found by walking each application's supervision tree (application master →
  its helper process → top supervisor, then children of type supervisor), so the cost
  depends on the number of supervisors, not processes (100k processes, saturated node:
  0.2–0.6 s vs 82 s for a full scan; measured 2026-10-02). The `all_supervisors` query
  option (MCP argument, `--all-supervisors`) scans every process instead, which also finds
  supervisors outside any application tree. Both recognize supervisors by `$initial_call`
  (Supervisor, DynamicSupervisor, Task.Supervisor) and only call those: a child declared
  `type: :supervisor` that is not one is never sent `which_children` (it would crash it;
  tested). `which_children` with a 1s timeout, `unreachable` if no answer. No
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
  Multi-node tests use `:peer` nodes with only Elixir on their code path (no Porthole, no
  `exqlite`), which proves observed nodes need nothing from Porthole.
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
