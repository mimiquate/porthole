# Porthole

Read-only SQL over a live BEAM system, built for coding agents.

A porthole is a window you can look through but not pass through. Porthole
exposes a running node's processes, supervisors, ETS tables and applications
as SQL tables, so an agent can compose one precise question instead of calling
many narrow tools. It is a sibling of Airlock: Airlock controls what agents can
*do*, Porthole controls what they can *see*.

> **Status:** spike. Only the `observe` capability tier is implemented.

## Usage

```console
# Try it on a tree of deliberately misbehaving processes (dev only)
$ mix porthole.query --demo \
    "SELECT initial_call, sum(message_queue_len) AS queued FROM processes GROUP BY 1 ORDER BY 2 DESC LIMIT 3"

# Query a running app from a separate VM; sample over 5s for _delta columns
$ mix porthole.query --connect my_app@127.0.0.1 --cookie secret --window 5000 \
    "SELECT registered_name, reductions_delta FROM processes ORDER BY 2 DESC LIMIT 10"
```

From a remote shell or IEx: `Porthole.print("SELECT ...")`, or
`Porthole.query/2` for a `Porthole.Result`.

For agents, Porthole is an MCP server with one `query` tool.

- **In development**, `mix porthole.mcp` serves it on stdio, next to the agent
  (run `mix compile` first):

  ```json
  {"mcpServers": {"porthole": {"command": "mix",
    "args": ["porthole.mcp", "--connect", "my_app@localhost", "--cookie", "dev"]}}}
  ```

- **In production**, `mix porthole.server` runs a sidecar inside the cluster
  that holds the cookie and serves MCP over HTTP. Agents get a URL and a token
  (`mix porthole.gen.token`), never the cookie:

  ```console
  $ mix porthole.server --connect my_app@10.0.1.12 --cookie "$RELEASE_COOKIE" --all-nodes --bind 0.0.0.0
  $ claude mcp add --transport http porthole https://porthole.internal:4040/ \
      --header "Authorization: Bearer ph_..."
  ```

### Example questions

```sql
-- Which ETS tables grow fastest, and who owns them? (--window 10000)
SELECT e.name, e.size_delta, p.registered_name AS owner
FROM ets_tables e JOIN processes p ON p.node = e.node AND p.pid = e.owner
ORDER BY e.size_delta DESC LIMIT 5;

-- Which application's processes use the most memory?
SELECT application, count(*), sum(memory) FROM processes GROUP BY 1 ORDER BY 3 DESC;

-- Orphans: no links, no monitors, not supervised
SELECT pid, initial_call FROM processes
WHERE links_count = 0 AND monitors_count = 0 AND monitored_by_count = 0
  AND pid NOT IN (SELECT child_pid FROM supervisors WHERE child_pid IS NOT NULL);
```

## Guides

- [What agents do with Porthole](guides/use-cases.md): the six situations
  teams use it in, with the queries and workflows for each.
- [Query cookbook](guides/cookbook.md): copy-paste queries by question, all
  tested against a live demo system.
- [Setting up your team](guides/team-setup.md): development and production
  setup, agent instructions, policy, audit, and the trust boundary.

## Tables

| Table          | One row per       | Columns                                                                                                   |
|----------------|-------------------|-----------------------------------------------------------------------------------------------------------|
| `processes`    | process           | pid, registered_name, initial_call, current_function, waiting_on, label, application, ancestors, status, message_queue_len, memory, binary_memory, reductions, links/monitors/monitored_by counts |
| `supervisors`  | supervisor child  | pid, name, module, child_id, child_pid, child_status, child_type                                          |
| `ets_tables`   | ETS table         | id, name, owner, type, protection, size, memory                                                           |
| `ports`        | port / socket     | port, name, owner, local_address, remote_address, os_pid, input, output, queue_size, memory               |
| `applications` | loaded app        | name, vsn, description, running                                                                           |
| `system`       | node              | memory by category, process/atom/port/ETS counts vs limits, run_queue, schedulers, uptime                 |

Every table has a `node` column. With a window, `processes` gains
`reductions_delta`, `memory_delta`, `message_queue_len_delta` and
`binary_memory_delta`, `ets_tables` gains `size_delta` and `memory_delta`,
`ports` gains `input_delta`, `output_delta` and `queue_size_delta`, and
`system` gains deltas for memory, process and port counts, and reductions.

## How it works

For every query, Porthole finds the tables the SQL mentions, collects them
right now on each requested node (`:erpc.multicall`), loads the rows into a
fresh in-memory SQLite database, runs the query and throws the database away.
SQLite is a query engine here, not a replica: it provides the joins,
aggregates and subqueries, and the running system stays the source of truth.

- **Read-only.** A SQLite authorizer denies all writes, `ATTACH`, `PRAGMA` and
  schema changes. Collectors read metadata only, never ETS contents or process
  state.
- **Bounded.** Rows collected, rows returned, cell size, term size and query
  time are capped. `truncated` and `notes` say what was cut.
- **Not atomic.** Processes change while a table is walked.
- **Sidecar-friendly.** Only the querying node needs SQLite (`exqlite` is an
  optional dependency). Observed nodes need only the pure-Elixir collectors.
- **Authenticated.** The HTTP server requires a bearer token per client; each
  token carries its own policy, and removing it revokes access.
- **Policies** define every tier (`observe`, `trace`, `evaluate`, `mutate`)
  and compose by intersection: `config :porthole, :policy` ∩ session ∩
  request.
- **Auditable.** Every query from an agent is recorded as structured JSON
  (client, SQL, nodes, outcome, duration); every query also emits
  `[:porthole, :query, *]` telemetry.
- **Versions.** Elixir 1.18+ and OTP 27+ on every node, tested in CI.

## Development

```console
$ mix test   # includes multi-node tests using :peer
```

`test/porthole/eval_test.exs` answers each eval question with one query
against `Porthole.Demo`.
