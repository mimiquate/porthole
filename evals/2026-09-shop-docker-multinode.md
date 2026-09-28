# Eval: blind diagnosis across two nodes, through the Docker sidecar (2026-09-28)

The [first eval](2026-09-shop-blind.md) ran against one node, with Porthole
serving from a mix task. This one runs the way a team would deploy it: the
app on **two nodes**, and the agent reaching them only through the
**packaged sidecar**, running as a Docker container.

## Setup

- **App:** two containers running the `:shop` demo (nine planted problems,
  neutral names, see the [method](README.md)), each a node named by its IP
  (`shop@172.20.0.2`, `shop@172.20.0.3`) with a **fixed cookie**, as a
  clustered production app.
- **Sidecar:** the `sidecar/Dockerfile` image, configured with only
  `RELEASE_COOKIE`, `PORTHOLE_TOKENS` and `DNS_CLUSTER_QUERY=app` (Docker's
  DNS standing in for the cluster's). It found both nodes by itself.
- **Agent:** a fresh Claude Code session in an empty folder outside the
  repository, connected to the sidecar over HTTP with a token. The session
  log confirms it used only the Porthole tool: no file reads, no shell.
- Both nodes had been up about 3.5 minutes when the agent started.

### Prompt

> Our shop app is running in production on several nodes. Users say checkout
> is slow and memory keeps growing. Use the porthole-docker tool (read-only
> SQL over the live cluster) to investigate what's wrong, on each node, and
> report the problems you find with evidence.

The prompt does not say how many nodes there are or what they are called.

## Scorecard

| # | Planted problem | Culprit | Result |
|---|---|---|---|
| 1 | Serializing bottleneck | `Shop.Pricing` | ✅ found on both nodes |
| 2 | CPU hog | `Shop.Inventory.Sync` | ✅ found, and inferred the cause (an immediate self-send) from `current_function` |
| 3 | Deadlock | `Shop.Cart` ⇄ `Shop.Promotions` | ✅ found |
| 4 | Stuck, flooded mailbox | `Shop.Notifications` | ✅ found; ❌ sender not named |
| 5 | ETS table growing forever | `shop_search_index` | ✅ found |
| 6 | Memory leak (state and binaries) | `Shop.Analytics` | ✅ found |
| 7 | Crash-looping child | `Shop.Payments.Gateway` | ✅ found, **measured**: its pid changed on every check |
| 8 | Socket leak | `Shop.Metrics.Reporter` | ✅ found |
| 9 | Orphan process | `:shop_import_watcher` | ❌ missed |
| | **Found** | | **8/9** |
| | **Time to report** | | ~1 min 30 s |
| | **Queries** | | 16 (2 errors, both recovered) |
| | **Wrong claims** | | none |
| | **Changes to the nodes** | | none (read-only by construction) |

The sidecar's audit log recorded the same 16 queries, attributed to the
agent's token.

## How it worked

**Both nodes, without being told.** The agent's first queries returned rows
from two nodes, and every later query kept `node` in joins and results. Its
report states that each problem "shows up the same way on both nodes".

**Measuring a restart loop.** Porthole has no restart counter (it lives in
supervisor state). The agent queried the crash-looping child three times,
seconds apart, and saw a different pid every time (`0.10446 → 0.10990 →
0.11525`), never alive long enough to be sampled. That is direct evidence
rather than the inference the first eval relied on.

**Recovering from its own mistakes.** Query 4 selected from a table that
does not exist, on purpose: the error lists the available tables. Query 9
used `connected` for a port's owner (the field name in Erlang's
`Port.info`); Porthole calls it `owner`, and the agent fixed it in query 14.

**The miss.** Its broad queries did surface processes with no links, but its
focused follow-up filtered on a list of `Shop.*` registered names, and the
orphan is registered as `shop_import_watcher` (lowercase). A realistic miss:
orphans are often the processes that don't follow the naming conventions.

### The queries

<details>
<summary>All 16 queries, in order</summary>

```sql
-- 1. What tables exist? (returns nothing: the database only holds tables a query mentions)
SELECT name FROM sqlite_master WHERE type='table'

-- 2. Largest mailboxes and memory
SELECT node, pid, registered_name, initial_call, current_function, waiting_on, status,
       message_queue_len, memory, binary_memory, reductions
FROM processes ORDER BY message_queue_len DESC, memory DESC LIMIT 25

-- 3. What is changing? (window 5 s)
SELECT node, pid, registered_name, current_function, status, message_queue_len,
       message_queue_len_delta, memory, memory_delta, binary_memory_delta, reductions_delta
FROM processes
WHERE reductions_delta > 1000 OR memory_delta <> 0 OR message_queue_len_delta <> 0
ORDER BY reductions_delta DESC LIMIT 30

-- 4. Deliberate error, to get the list of tables
SELECT * FROM nonexistent_table_xyz

-- 5. Who waits on whom
SELECT w.node, w.pid, w.registered_name, w.initial_call, w.current_function, w.waiting_on,
       t.registered_name AS target, t.current_function AS target_fn, w.label
FROM processes w LEFT JOIN processes t ON t.node = w.node AND t.pid = w.waiting_on
WHERE w.waiting_on IS NOT NULL

-- 6. Largest ETS tables (window 5 s)
SELECT node, name, type, size, memory, owner, protection FROM ets_tables ORDER BY memory DESC LIMIT 15

-- 7. Node overview
SELECT * FROM system

-- 8. The growing table (window 5 s)
SELECT * FROM ets_tables WHERE name = 'shop_search_index'

-- 9. Ports by owner (error: the column is `owner`, not `connected`)
SELECT p.node, p.name, p.connected, pr.registered_name, pr.initial_call, count(*) AS n
FROM ports p LEFT JOIN processes pr ON pr.node = p.node AND pr.pid = p.connected
GROUP BY 1,2,3,4,5 ORDER BY n DESC LIMIT 15

-- 10. The app's supervisors
SELECT * FROM supervisors WHERE name LIKE 'Shop%' OR module LIKE 'Shop%'

-- 11. The suspicious child
SELECT node, child_id, child_pid FROM supervisors WHERE child_id = 'Shop.Payments.Gateway'

-- 12. What a port row looks like
SELECT * FROM ports LIMIT 3

-- 13. Drill-down on named processes and heavily linked or monitored ones
SELECT node, pid, registered_name, current_function, status, memory, binary_memory, links_count,
       monitors_count, monitored_by_count, message_queue_len, reductions
FROM processes
WHERE registered_name IN ('Shop.Importer', 'Shop.Orders.EventRelay', 'Shop.Metrics.Reporter',
                          'Shop.Payments.Ledger', 'Shop.Payments.Gateway', 'Shop.Inventory.Sync',
                          'Shop.Search.Indexer', 'Shop.Analytics')
   OR monitors_count > 5 OR monitored_by_count > 5 OR links_count > 20

-- 14. Ports by owner (fixed)
SELECT p.node, p.owner, pr.registered_name, p.name, count(*) n, sum(p.memory) mem
FROM ports p LEFT JOIN processes pr ON pr.node = p.node AND pr.pid = p.owner
GROUP BY 1,2,3,4 ORDER BY n DESC LIMIT 8

-- 15. How many processes has the payments tree used up?
SELECT node, count(*) n, min(pid), max(pid), sum(memory)
FROM processes WHERE ancestors LIKE '%Payments%' OR initial_call LIKE '%Gateway%' GROUP BY node

-- 16. The Gateway again (its pid had changed), plus two checks in one query
SELECT s.node, s.child_pid, p.status, p.current_function,
       (SELECT count(*) FROM ports x WHERE x.node = s.node AND x.owner = '#PID<0.240.0>') AS reporter_ports,
       (SELECT memory FROM processes a WHERE a.node = s.node AND a.registered_name = 'Shop.Analytics') AS analytics_mem
FROM supervisors s LEFT JOIN processes p ON p.node = s.node AND p.pid = s.child_pid
WHERE s.child_id = 'Shop.Payments.Gateway'
```

</details>

### The agent's report (abridged)

> I found seven problems, and they show up the same way on both nodes
> (`shop@172.20.0.2` and `shop@172.20.0.3`). Both nodes had been up about 3.5
> minutes. [...] All of this is inferred from process state in the live
> cluster; I didn't read the source code.
>
> **Checkout is slow**
>
> 1. **All 10 checkout workers are stuck waiting on `Shop.Pricing`, which is
>    sleeping.** It sits in `Process.sleep/1` while handling a request, with 9
>    more requests queued. Every `Shop.Checkout.Worker` is blocked in
>    `:gen.do_call/4` waiting on that one process.
> 2. **`Shop.Cart` and `Shop.Promotions` are deadlocked.** Each waits on the
>    other. Neither has done any work since it started (66 and 57
>    reductions).
> 3. **`Shop.Payments.Gateway` keeps crashing and restarting.** Its process ID
>    changed every time I checked, even between queries seconds apart (0.10446
>    → 0.10990 → 0.11525 on .2, and similarly on .3). `Shop.Payments.Supervisor`
>    is doing about 22k reductions per second just restarting it.
> 4. **`Shop.Inventory.Sync` is using CPU in a hot loop.** About 108 million
>    reductions per second. Its current function alternates between
>    `handle_info/2` and `:erlang.send/2`, and it always has 1 message queued.
>    It looks like it sends a message to itself and handles it with no delay.
>
> **Memory keeps growing**
>
> 5. **`Shop.Notifications` has an ever-growing mailbox (the biggest leak).**
>    About 990,000 messages, growing by about 5,200 per second; about 111 MB,
>    growing by about 580 KB per second. It is stuck in `handle_continue/2`.
> 6. **The `shop_search_index` ETS table grows without limit.** 2.2 million
>    rows and 142 MB, gaining about 10,000 rows (640 KB) per second, owned by
>    `Shop.Search.Indexer`.
> 7. **`Shop.Analytics` holds on to a large amount of binary data.** 41–45 MB
>    of process memory plus 19–23 MB of binaries, gaining about 106 KB of
>    binaries per second.
>
> **Minor:** `Shop.Metrics.Reporter` owns 200 open UDP sockets.
>
> **Suggested order to fix:** Pricing and the deadlock (checkout), then the
> Gateway crash, then the Notifications backlog and the search index
> (memory), then the hot loop, then Analytics.

## An earlier, non-blind run

A first attempt with the same setup ran from inside the repository. While
Claude Code's permission check was failing, the agent listed the section
headings of `guides/` (it did not open the demo's source or the evals). It
then found 8/9 as well, missing `Shop.Analytics`: after nine minutes of
uptime, two larger leaks (318 MB and 364 MB) hid it. Because it had seen the
guides' headings, that run is not counted. It is why the method now insists
on a folder outside the repository.

## What this suggests for Porthole

- **Agents list tables first.** The schema is in the tool description, yet
  the agent's first query was `SELECT name FROM sqlite_master`, which returns
  nothing (each database only holds the tables a query mentions), and its
  fourth was a deliberate error to get the table list. Answering those
  introspection queries with Porthole's tables would save two round trips.
- **Pre-approve the tool.** In both Docker runs, Claude Code's auto-mode
  permission check intermittently failed on the Porthole tool. Since it is
  read-only, allowing it explicitly (`mcp__<server>__query`) removes the check
  altogether; the team-setup guide now recommends it.
- **Measured restarts.** The agent's pid-change method could be built in: a
  sampled column on `supervisors` flagging children whose pid changed during
  the window.
