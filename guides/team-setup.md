# Setting up your team

This guide covers what a team does so its agents can use Porthole:
installation, development and production setups, the instructions that tell
agents when and how to use it, and the human side of the workflow.

## Install

Add Porthole to your application. Only the node that *runs queries* needs
SQLite, so `exqlite` can be a dev-only dependency:

```elixir
def deps do
  [
    {:porthole, "~> 0.1"},
    # Only where queries run: your laptop, or the sidecar. Not your releases.
    {:exqlite, "~> 0.41", only: :dev}
  ]
end
```

Nodes that are only *observed* (your production release) carry Porthole's
collectors: plain Elixir, no NIFs, no processes, no configuration.

## Development

The agent talks to your running dev server through an MCP server that joins
it as a hidden node.

**1. Start your dev server as a named node:**

```console
$ iex --sname my_app@localhost --cookie dev -S mix phx.server
```

**2. Add the MCP server to the repo**, e.g. `.mcp.json` for Claude Code (other
MCP clients take the same command and arguments):

```json
{
  "mcpServers": {
    "porthole": {
      "command": "mix",
      "args": ["porthole.mcp", "--connect", "my_app@localhost", "--cookie", "dev"]
    }
  }
}
```

**3. Compile once before the agent starts** (`mix compile`). The MCP server
speaks over stdout, and compiler output there would corrupt the protocol.

That's it. The agent now has a `query` tool whose description includes the
full schema. To try things without your app, `mix porthole.query --demo "..."`
runs queries against a built-in tree of misbehaving processes.

## Tell your agent when to use it

Agents use tools they are told about. Add something like this to your
`AGENTS.md` / `CLAUDE.md`:

```markdown
## Inspecting the running system (Porthole)

The `porthole` MCP tool runs read-only SQL against the running app. Use it
instead of guessing about runtime state.

- After changing processes, supervisors or ETS tables, verify with a query that
  they exist where expected, then exercise the feature and check again.
- When something hangs or times out, follow `processes.waiting_on` to find who
  is blocked on whom.
- For resource problems, start with the `system` table, rank with
  `ORDER BY ... LIMIT`, and pass `window_ms` to measure change (`_delta` columns)
  before concluding something is growing.
- Explain findings in terms of our code: group or join by `initial_call`,
  `application` and `supervisors`, not raw pids.
- Join on `node` as well as pids. Aggregate in SQL; don't fetch raw rows.
- If a result says `truncated: true`, read `notes` before trusting counts.
- Porthole cannot kill, restart or change anything. Propose actions; a human
  takes them.
```

Add team-specific knowledge too: the names of your critical processes and
tables, what "normal" looks like (e.g. "the pool has 10 connections per node,
mailboxes above 100 are unusual"), and links to your runbooks.

## Production

In production, the agent should reach the cluster through a **sidecar**: a
separate VM that joins the cluster as a hidden node, runs the queries (it is
the only place SQLite runs) and exposes the MCP tool. Production nodes need
only the `porthole` dependency in their release.

```console
$ mix porthole.mcp --connect my_app@10.0.1.12 --cookie "$RELEASE_COOKIE" --all-nodes
```

`--all-nodes` makes every query fan out to the target and every node it is
connected to, and each row carries its `node`.

### Understand the trust boundary

Porthole guarantees that **its tool** is read-only: queries cannot write, and
collectors only read metadata. But the sidecar holds the distribution cookie,
and **the cookie grants full control of the cluster**: anything with it can
connect and run arbitrary code. So:

- The agent must have the MCP tool, **not** the cookie. Do not run a
  production sidecar where the agent also has a shell or file access that can
  read the cookie (from `.mcp.json`, environment variables or process
  arguments): with the cookie, it could bypass Porthole entirely.
- In practice today: run production investigations from a client without
  shell access for the agent, or keep the sidecar on a host the agent cannot
  inspect. A remote (HTTP) MCP transport that keeps the cookie off the
  agent's machine entirely is planned.
- Scope the sidecar with a policy (below), and review the audit log.

### Policy

The node running the queries reads its policy from config. Everything a
request asks for is intersected with it, so it can only narrow:

```elixir
# config/config.exs (or runtime.exs) of the project running the sidecar
config :porthole, :policy,
  nodes: [:"my_app@10.0.1.12", :"my_app@10.0.1.13"],
  max_rows: 50_000,
  max_result_rows: 200,
  max_window_ms: 30_000,
  timeout_ms: 10_000
```

Only the `observe` tier is implemented. The `trace`, `evaluate` and `mutate`
tiers are defined so policies can be written against them, and they return a
"not enabled" error.

### Audit

The MCP server logs every query to stderr: the SQL, the nodes, the window
and the outcome. Keep those logs: they record exactly what the agent looked
at.

```text
[info] porthole query [3 rows] nodes=[:"my_app@10.0.1.12"] window_ms=10000: SELECT ...
```

When calling `Porthole.query/2` from your own code, attach to the
`[:porthole, :query, :stop]` telemetry event instead.

### Cost

Each query collects only the tables it mentions, once (twice with a window).
Collecting `processes` calls `Process.info/2` for every process, so on a node
with a million processes a query costs roughly what `:observer`'s process
tab costs for one refresh. Collection is capped by `max_rows`, and a capped
result says so in `notes`. Nothing runs between queries.

## The human side

Porthole changes what the agent can see, not who is responsible. Teams that
get value from it tend to:

- **Start in development.** Most of the value is in the daily loop of
  verifying changes. It is also where people learn to trust the answers.
- **Keep a human on the action.** In an incident, the agent investigates and
  proposes; a human restarts, kills, scales or rolls back.
- **Write down "normal".** An agent can tell that a mailbox has 5,000
  messages; only your team knows whether that is normal. Put it in the agent
  instructions.
- **Turn incidents into queries.** After an incident, save the query that
  found the cause in your runbook (or contribute it to the
  [cookbook](cookbook.md)). The next investigation starts there.
