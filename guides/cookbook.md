# Query cookbook

Copy-paste queries, grouped by question. Every query here is run against a
live demo system in Porthole's test suite, so they stay correct as the schema
evolves. Queries marked `-- window_ms: N` need a sampling window: pass
`window_ms` to the MCP tool, `--window` to `mix porthole.query`, or
`window_ms:` to `Porthole.query/2`.

Conventions that apply to every query:

- Every table has a `node` column. When joining, join on `node` **and** the
  pid; pids are only unique within a node.
- Pids are text (`'#PID<0.123.0>'`), memory is bytes, booleans are `0`/`1`.
- Aggregate and `LIMIT` in SQL. Results are capped, and `truncated` plus
  `notes` tell you when something was cut.

## The node

Memory, limits and scheduler pressure, one row per node:

```sql
SELECT node, memory_total / 1048576 AS total_mb, memory_processes / 1048576 AS processes_mb,
       memory_binary / 1048576 AS binary_mb, memory_ets / 1048576 AS ets_mb,
       run_queue, schedulers_online, process_count, atom_count, port_count
FROM system;
```

How close is each node to a VM limit?

```sql
SELECT node,
       round(100.0 * process_count / process_limit, 1) AS process_pct,
       round(100.0 * atom_count / atom_limit, 1) AS atom_pct,
       round(100.0 * port_count / port_limit, 1) AS port_pct,
       round(100.0 * ets_count / ets_limit, 1) AS ets_pct
FROM system;
```

What is growing at the VM level?

```sql
-- window_ms: 5000
SELECT node, memory_total_delta, memory_processes_delta, memory_binary_delta,
       memory_ets_delta, process_count_delta, port_count_delta, reductions_delta
FROM system;
```

## Processes

What kinds of processes are running, and how many of each?

```sql
SELECT initial_call, count(*) AS processes, sum(memory) AS memory
FROM processes
GROUP BY initial_call
ORDER BY processes DESC
LIMIT 20;
```

Biggest processes by memory:

```sql
SELECT pid, registered_name, initial_call, current_function, memory, message_queue_len
FROM processes
ORDER BY memory DESC
LIMIT 10;
```

Which processes burn the most CPU?

```sql
-- window_ms: 5000
SELECT pid, registered_name, initial_call, current_function, reductions_delta
FROM processes
ORDER BY reductions_delta DESC
LIMIT 10;
```

Which processes are growing?

```sql
-- window_ms: 10000
SELECT pid, registered_name, initial_call, memory, memory_delta, binary_memory_delta
FROM processes
ORDER BY memory_delta DESC
LIMIT 10;
```

Who holds the most off-heap binaries? (a classic leak: a long-lived process
keeping references to large binaries it no longer needs)

```sql
SELECT pid, registered_name, initial_call, binary_memory, memory
FROM processes
ORDER BY binary_memory DESC
LIMIT 10;
```

Memory by application:

```sql
SELECT application, count(*) AS processes, sum(memory) / 1048576 AS memory_mb
FROM processes
GROUP BY application
ORDER BY memory_mb DESC;
```

Processes carrying a label (set with `Process.set_label/1`):

```sql
SELECT label, count(*) AS processes, sum(memory) AS memory
FROM processes
WHERE label IS NOT NULL
GROUP BY label
ORDER BY processes DESC
LIMIT 20;
```

Orphans: no links, no monitors, not supervised.

```sql
SELECT pid, registered_name, initial_call, current_function, memory
FROM processes
WHERE links_count = 0 AND monitors_count = 0 AND monitored_by_count = 0
  AND pid NOT IN (SELECT child_pid FROM supervisors WHERE child_pid IS NOT NULL);
```

A few VM processes (such as `erts_code_purger`) always match. Add
`AND application = 'my_app'` to focus on processes your code started.

## Mailboxes and blocking

Largest mailboxes, grouped by what the processes are:

```sql
SELECT initial_call, count(*) AS processes, sum(message_queue_len) AS queued,
       max(message_queue_len) AS worst
FROM processes
GROUP BY initial_call
HAVING queued > 0
ORDER BY queued DESC
LIMIT 10;
```

Mailboxes that are growing (a process that cannot keep up):

```sql
-- window_ms: 5000
SELECT pid, registered_name, initial_call, message_queue_len, message_queue_len_delta
FROM processes
WHERE message_queue_len_delta > 0
ORDER BY message_queue_len_delta DESC
LIMIT 10;
```

Which processes serialize work? (many callers blocked on one process)

```sql
SELECT target.pid, target.registered_name, target.initial_call, target.status,
       target.message_queue_len, count(*) AS blocked_callers
FROM processes caller
JOIN processes target ON target.node = caller.node AND target.pid = caller.waiting_on
GROUP BY target.node, target.pid
ORDER BY blocked_callers DESC
LIMIT 10;
```

Deadlocks (cycles of `waiting_on`):

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

## Supervision

The supervision tree under one supervisor:

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

Children that are not running:

```sql
SELECT name AS supervisor, child_id, child_status
FROM supervisors
WHERE child_status <> 'running';
```

Which supervisor is restarting children? Restarting costs the supervisor
work, so a busy supervisor is the signal:

```sql
-- window_ms: 5000
SELECT s.name, s.module, p.reductions_delta, p.message_queue_len
FROM processes p
JOIN (SELECT DISTINCT node, pid, name, module FROM supervisors) s
  ON s.node = p.node AND s.pid = p.pid
ORDER BY p.reductions_delta DESC
LIMIT 5;
```

Supervisors with the most children (usually dynamic ones):

```sql
SELECT node, name, pid, count(*) AS children
FROM supervisors
GROUP BY node, pid
ORDER BY children DESC
LIMIT 10;
```

## ETS

Largest tables, with their owners:

```sql
SELECT e.name, e.type, e.protection, e.size, e.memory / 1024 AS kb,
       coalesce(p.registered_name, p.initial_call) AS owner
FROM ets_tables e
JOIN processes p ON p.node = e.node AND p.pid = e.owner
ORDER BY e.memory DESC
LIMIT 10;
```

Fastest-growing tables:

```sql
-- window_ms: 10000
SELECT e.name, e.size, e.size_delta, e.memory_delta,
       coalesce(p.registered_name, p.initial_call) AS owner
FROM ets_tables e
JOIN processes p ON p.node = e.node AND p.pid = e.owner
ORDER BY e.size_delta DESC
LIMIT 10;
```

## Ports and sockets

Who owns the most sockets?

```sql
SELECT coalesce(p.registered_name, p.initial_call) AS owner, count(*) AS sockets
FROM ports s
JOIN processes p ON p.node = s.node AND p.pid = s.owner
WHERE s.name IN ('tcp_inet', 'udp_inet')
GROUP BY p.node, p.pid
ORDER BY sockets DESC
LIMIT 10;
```

What does this node talk to?

```sql
SELECT s.remote_address, count(*) AS connections, group_concat(DISTINCT p.initial_call) AS owners
FROM ports s
JOIN processes p ON p.node = s.node AND p.pid = s.owner
WHERE s.remote_address IS NOT NULL
GROUP BY s.remote_address
ORDER BY connections DESC;
```

Sockets that cannot write fast enough (bytes queued in the driver):

```sql
SELECT s.port, s.remote_address, s.queue_size, coalesce(p.registered_name, p.initial_call) AS owner
FROM ports s
JOIN processes p ON p.node = s.node AND p.pid = s.owner
WHERE s.queue_size > 0
ORDER BY s.queue_size DESC
LIMIT 10;
```

Busiest connections:

```sql
-- window_ms: 5000
SELECT port, remote_address, input_delta, output_delta
FROM ports
ORDER BY input_delta + output_delta DESC
LIMIT 10;
```

## Cluster and deploys

Applications running different versions on different nodes:

```sql
SELECT name, count(DISTINCT vsn) AS versions, group_concat(DISTINCT vsn) AS vsns
FROM applications
WHERE running = 1
GROUP BY name
HAVING count(DISTINCT vsn) > 1;
```

Node overview after a deploy:

```sql
SELECT node, uptime_ms / 60000 AS uptime_min, process_count,
       memory_total / 1048576 AS memory_mb, run_queue
FROM system
ORDER BY node;
```

Compare process populations across nodes:

```sql
SELECT initial_call, node, count(*) AS processes
FROM processes
GROUP BY initial_call, node
ORDER BY initial_call, node;
```
