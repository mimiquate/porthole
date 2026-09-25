# What agents do with Porthole

A coding agent can read your code, run your tests and tail your logs. What it
cannot do is *look at the running system*. So it guesses: it assumes the new
GenServer started, that the cache fills, that the pool is not saturated.

Porthole gives the agent a read-only window into a live BEAM node. The agent
asks questions in SQL, and gets back small, precise answers from runtime
state that is collected at the moment it asks.

This guide walks through the six situations where we expect teams to use it,
from the most frequent to the most valuable. For each, it shows what the agent
asks, the workflow it follows, and what it still cannot see. The
[query cookbook](cookbook.md) has every query in one place, and
[Setting up your team](team-setup.md) covers the setup.

## How an agent investigates

Almost every investigation follows the same three moves. Teach your agent this
pattern (the [agent instructions](team-setup.md#tell-your-agent-when-to-use-it)
do):

1. **Look wide.** Start from totals: the `system` table, or counts grouped by
   something meaningful (`initial_call`, `application`, `node`).
2. **Rank.** `ORDER BY <symptom> DESC LIMIT 10` finds the few processes, tables
   or sockets that matter out of hundreds of thousands.
3. **Explain.** Join the suspects to what gives them meaning: who spawned them
   (`initial_call`, `ancestors`), who supervises them (`supervisors`), who
   they are waiting on (`waiting_on`), what they own (`ets_tables`, `ports`).
   When the question is about *change* ("growing", "busy"), sample over a
   window and use the `_delta` columns.

Porthole returns aggregated, capped results. An agent that aggregates in SQL
instead of fetching raw rows gets correct answers in a few hundred tokens.

---

## 1. Verifying a change in development

**How often:** many times a day. **Stakes:** low. **What matters:** zero friction.

The agent just added a cache, a worker pool or a new supervisor. Instead of
assuming it works, it checks.

*Did my new process start, and is it supervised where I intended?*

```sql
SELECT s.name AS supervisor, s.child_id, s.child_status, p.pid, p.message_queue_len
FROM supervisors s
LEFT JOIN processes p ON p.node = s.node AND p.pid = s.child_pid
WHERE s.child_id LIKE 'MyApp.Cache%';
```

*Did the ETS table get created, and does it fill when the endpoint is hit?*

```sql
-- window_ms: 5000
SELECT name, owner, protection, size, size_delta, memory
FROM ets_tables
WHERE name = 'my_app_cache';
```

*Does this code path leak processes?* The agent runs this, exercises the
feature (a request, a test, a LiveView page load), then runs it again and
compares:

```sql
SELECT initial_call, count(*) AS processes
FROM processes
GROUP BY initial_call
ORDER BY processes DESC
LIMIT 20;
```

**Workflow.** Change code → recompile or restart the dev server → query →
exercise the feature → query again → compare → fix or move on.

**The team needs:** the dev server running as a named node and the MCP server
configured in the repo ([setup](team-setup.md#development)), plus an
instruction telling the agent to verify runtime changes instead of assuming
them.

## 2. Debugging a hang or a timeout

**How often:** weekly. **Stakes:** medium. **What matters:** "who is waiting on whom".

A request hangs, a test times out, a `GenServer.call` exits with `:timeout`.
The code looks right. The runtime shows what is actually happening.

*Who is blocked, and on what?* `waiting_on` is set for processes blocked in
`GenServer.call` (and any `gen` call: `Agent`, `:gen_statem`, `Supervisor`
calls) or `Task.await`:

```sql
SELECT caller.registered_name AS caller, caller.initial_call AS caller_call,
       target.registered_name AS target, target.initial_call AS target_call,
       target.status, target.current_function, target.message_queue_len
FROM processes caller
JOIN processes target ON target.node = caller.node AND target.pid = caller.waiting_on
ORDER BY target.message_queue_len DESC
LIMIT 20;
```

*Is it a deadlock?* Follow the `waiting_on` chain; a chain that comes back to
where it started is a cycle:

```sql
WITH RECURSIVE chain(node, start, pid, path, depth) AS (
  SELECT node, pid, waiting_on, coalesce(registered_name, pid), 1
  FROM processes WHERE waiting_on IS NOT NULL
  UNION ALL
  SELECT c.node, c.start, p.waiting_on, c.path || ' -> ' || coalesce(p.registered_name, p.pid), c.depth + 1
  FROM chain c JOIN processes p ON p.node = c.node AND p.pid = c.pid
  WHERE p.waiting_on IS NOT NULL AND c.pid <> c.start AND c.depth < 20
)
SELECT node, path AS cycle FROM chain WHERE pid = start;
```

Each member of a cycle is listed once, as the starting point of its own
path. Chains are followed within a node; calls across nodes are not linked.

**Workflow.** Reproduce the hang and keep it hanging → find blocked callers →
follow `waiting_on` to the end of the chain → look at the process at the end:

- also waiting on someone in the chain → **deadlock** (the cycle query shows it);
- `running`, with a high `reductions_delta` → it is **slow**, doing real work;
- `waiting`, with a growing mailbox → it is a **bottleneck**, serializing calls;
- waiting on something outside the BEAM (e.g. `current_function` in a socket
  or port call) → the problem is **downstream** (database, HTTP, disk).

**Cannot see yet:** the message a caller sent, or the full stack of the
blocked process beyond `current_function`.

## 3. Production incident triage

**How often:** rarely. **Stakes:** high. **What matters:** fast, safe, correct answers.

Latency is up, memory is climbing, a node is restarting. The agent works from
a sidecar (a separate node that joins the cluster as a hidden node, see
[production setup](team-setup.md#production)). It can look, not touch.

**Look wide.** One row per node: memory by category, limits, scheduler pressure.

```sql
SELECT node,
       memory_total / 1048576 AS total_mb,
       memory_processes / 1048576 AS processes_mb,
       memory_binary / 1048576 AS binary_mb,
       memory_ets / 1048576 AS ets_mb,
       run_queue, schedulers_online,
       round(100.0 * process_count / process_limit, 1) AS process_pct,
       round(100.0 * atom_count / atom_limit, 1) AS atom_pct,
       round(100.0 * port_count / port_limit, 1) AS port_pct
FROM system
ORDER BY total_mb DESC;
```

That classifies the incident, and each class has its own next step:

| Symptom in `system` | Next question | Where to look |
|---|---|---|
| `memory_processes` high or growing | which processes? | `processes.memory`, `memory_delta` |
| `memory_binary` high or growing | who holds the binaries? | `processes.binary_memory`, `binary_memory_delta` |
| `memory_ets` high or growing | which tables, owned by whom? | `ets_tables.memory`, `size_delta` |
| `run_queue` persistently > `schedulers_online` | who burns CPU? | `processes.reductions_delta` |
| `port_pct` high | who opens sockets or files? | `ports` joined with `processes` |
| `atom_pct` high | something converts input to atoms | (code search; atoms are never freed) |
| latency up, resources normal | who serializes work? | `message_queue_len`, `waiting_on` |

**Rank and measure.** For example, memory growth over 10 seconds, across the cluster:

```sql
-- window_ms: 10000
SELECT node, registered_name, initial_call, memory, memory_delta, binary_memory_delta
FROM processes
ORDER BY memory_delta DESC
LIMIT 10;
```

**Explain.** Attribute the suspects to a supervisor or an application, so the
answer is about *your code*, not about a pid:

```sql
-- window_ms: 10000
SELECT p.application, p.initial_call, count(*) AS processes,
       sum(p.memory) AS memory, sum(p.memory_delta) AS growth
FROM processes p
GROUP BY p.application, p.initial_call
ORDER BY growth DESC
LIMIT 10;
```

**Hand off.** The agent reports what it found, with the queries as evidence,
and proposes an action: restart this worker, drain that queue, roll back that
deploy. A human takes the action. Porthole defines `mutate` and `evaluate`
capability tiers, but neither is enabled, by design.

**Workflow.** Look wide (`system`) → classify with the table above → rank →
sample to confirm it is *growing*, not just *big* → attribute (`initial_call`,
`application`, `supervisors`) → report with evidence → human acts.

**Cannot see yet:** *why* a process crashed (that is in your logs and error
tracker), what is inside a mailbox, process state, or anything that happened
before the query ran (Porthole keeps no history).

## 4. Understanding a system you did not write

**How often:** onboarding, audits, before a refactor. **Stakes:** low. **What matters:** an accurate map.

The runtime is the ground truth of an architecture. An agent can map it in a
few queries, and then explain it or check it against the docs.

*What does the supervision tree look like?*

```sql
WITH RECURSIVE tree(node, pid, label, depth, sort_key) AS (
  SELECT DISTINCT node, pid, name, 0, node || name FROM supervisors WHERE name = 'MyApp.Supervisor'
  UNION ALL
  SELECT s.node, s.child_pid, s.child_id || ' (' || s.child_type || ')', t.depth + 1,
         t.sort_key || '/' || s.child_id
  FROM tree t JOIN supervisors s ON s.node = t.node AND s.pid = t.pid
)
SELECT node, substr('                    ', 1, depth * 2) || label AS tree
FROM tree
ORDER BY sort_key;
```

*What does this node talk to?* Group connected sockets by peer, with the code
that owns them:

```sql
SELECT s.remote_address, count(*) AS connections,
       group_concat(DISTINCT p.initial_call) AS owners
FROM ports s
JOIN processes p ON p.node = s.node AND p.pid = s.owner
WHERE s.remote_address IS NOT NULL
GROUP BY s.remote_address
ORDER BY connections DESC;
```

*What state lives in ETS, and which process owns it?*

```sql
SELECT e.name, e.type, e.protection, e.size, e.memory / 1024 AS kb,
       coalesce(p.registered_name, p.initial_call) AS owner
FROM ets_tables e
JOIN processes p ON p.node = e.node AND p.pid = e.owner
ORDER BY e.memory DESC
LIMIT 20;
```

**Workflow.** Applications → supervision tree of the app → named processes →
ETS tables → outbound connections → write it up, or compare it with the
architecture docs and flag the drift.

## 5. Checking a deploy

**How often:** every deploy. **Stakes:** medium. **What matters:** "is every node what we expect?"

*Are all nodes running the same versions?* Any row here is a problem:

```sql
SELECT name, count(DISTINCT vsn) AS versions, group_concat(DISTINCT vsn) AS vsns,
       count(DISTINCT node) AS nodes
FROM applications
WHERE running = 1
GROUP BY name
HAVING count(DISTINCT vsn) > 1;
```

*Did every node come up, and do they look alike?*

```sql
SELECT node, uptime_ms / 60000 AS uptime_min, process_count,
       memory_total / 1048576 AS memory_mb, run_queue
FROM system
ORDER BY node;
```

*Is the new worker running on every node?*

```sql
SELECT node, count(*) AS workers
FROM processes
WHERE initial_call = 'MyApp.NewWorker.init/1'
GROUP BY node;
```

**Workflow.** After the deploy finishes: versions → uptime and shape per node
→ the processes the release was supposed to add → report. This is a good
candidate for running automatically in CI/CD, with the agent (or a script)
comparing results to expectations.

## 6. Inside the libraries you depend on

**How often:** whenever a dependency misbehaves. **Stakes:** medium. **What matters:** discovery.

Database pools, job queues, pipelines and PubSub are all processes. Their
internals differ, so the agent should **discover first**: every process knows
its `application`, so it can list what a library runs, then watch queues and
blocking.

```sql
SELECT application, initial_call, count(*) AS processes,
       sum(message_queue_len) AS queued, sum(memory) AS memory
FROM processes
WHERE application IN ('db_connection', 'oban', 'broadway', 'phoenix_pubsub')
GROUP BY application, initial_call
ORDER BY queued DESC;
```

*Are callers piling up on a library's processes?* (for libraries whose
processes are called with `GenServer.call`)

```sql
SELECT target.application, target.initial_call, count(*) AS blocked_callers
FROM processes caller
JOIN processes target ON target.node = caller.node AND target.pid = caller.waiting_on
GROUP BY target.application, target.initial_call
ORDER BY blocked_callers DESC;
```

**Workflow.** Discover the library's processes by `application` →
identify the ones that matter (pool, producer, queue) → watch mailboxes,
blocked callers and deltas under load → relate what you see to the library's
configuration.

---

## What Porthole cannot tell you (yet)

Being explicit about the gaps keeps agents from over-trusting the answers:

- **Why** something crashed or restarted: read the logs or the error tracker.
- **What** is in a mailbox or in a process's state: that needs the `evaluate`
  tier, which is not enabled.
- **Before now**: every query is a fresh snapshot, with no history. Use a
  window to measure change, and your metrics system for trends.
- **Atomicity**: rows are collected while the system runs, so two rows can
  describe slightly different instants.
- **Scheduler utilization**: `run_queue` is a proxy; true utilization would
  require turning on a VM flag, which Porthole does not do.
- **`:socket`-based connections**: only `gen_tcp`/`gen_udp` (inet driver)
  sockets appear in `ports`.
