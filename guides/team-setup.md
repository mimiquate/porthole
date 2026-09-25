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

In production, agents reach the cluster through a **sidecar**: a separate VM
that joins the cluster as a hidden node, holds the distribution cookie, runs
the queries (it is the only place SQLite runs) and serves MCP over HTTP.
Agents get a **URL and a token, never the cookie**.

```
Agent ──HTTPS + token──▶ sidecar (holds the cookie) ──distribution──▶ your nodes
```

Production nodes only need the `porthole` dependency in their release. The
sidecar is a project that depends on `porthole`, `exqlite`, `plug` and
`bandit`, deployed inside the cluster's private network.

### 1. Create a token per client

Each agent, team or person gets its own token, so the audit log says who
asked and each can be revoked on its own:

```console
$ mix porthole.gen.token oncall
Token for oncall (give this to the client; it is shown only once):

    ph_EXAMPLE-not-a-real-token

Add the entry to the server's config (one entry per client in the list):

    config :porthole, :tokens, [
      [id: "oncall", sha256: "fd07d512979f51c4..."]
    ]
```

Only the hash goes in the sidecar's configuration. A token can carry a policy
that narrows what that client sees:

```elixir
config :porthole, :tokens, [
  [id: "oncall", sha256: "fd07d5..."],
  [id: "ci-deploy-check", sha256: "60303a...", policy: [max_result_rows: 50]],
  [id: "contractor", sha256: "b5bb9d...", policy: [nodes: [:"my_app@staging-1"]]]
]
```

Removing an entry revokes the token.

### 2. Run the sidecar

```console
$ mix porthole.server --connect my_app@10.0.1.12 --cookie "$RELEASE_COOKIE" \
    --all-nodes --bind 0.0.0.0 --port 4040
```

Or add it to the sidecar's supervision tree:

```elixir
children = [
  {Porthole.Server, port: 4040, ip: {0, 0, 0, 0}, query_opts: [nodes: :all]}
]
```

The server refuses to start without at least one token. It listens on
`127.0.0.1` unless told otherwise, and serves HTTPS with `--certfile` and
`--keyfile`. Without those, terminate TLS in front of it (ingress, load
balancer): tokens must not travel in clear text outside a trusted network.

`--all-nodes` makes every query fan out to the target and every node it is
connected to; each row carries its `node`.

### 3. Connect the agent

```console
$ claude mcp add --transport http porthole https://porthole.internal:4040/ \
    --header "Authorization: Bearer ph_EXAMPLE-not-a-real-token"
```

Other MCP clients take the same URL and header.

### Understand the trust boundary

Porthole guarantees that **its tool** is read-only: queries cannot write,
and collectors only read metadata. The cookie is different: in Erlang
distribution it grants full control of the cluster, and there is no
read-only cookie. The sidecar keeps it out of the agent's reach, which holds
as long as:

- **Porthole is the agent's only route into production.** An agent that
  also has SSH, `kubectl exec`, `bin/my_app rpc` or cloud credentials can
  bypass it.
- **The sidecar is protected like any service holding cluster credentials.**
  Whoever controls its host has the cookie.
- **Everything outside the cluster goes over TLS**, since tokens are bearer
  credentials.

Observe access still reveals information (process and table names, labels,
the addresses your nodes connect to, versions). That is usually fine for an
engineering team, but it is a deliberate grant: scope tokens with policies.

The requests are checked before any work is done: missing or unknown tokens
get `401`, requests from browsers (with an `Origin` header) get `403` unless
allowed with `:allowed_origins`, and bodies over 1 MB are rejected.

### Policy

The environment policy is read from the sidecar's config. Every token's
policy and every request is intersected with it, so they can only narrow:

```elixir
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

Every query is recorded as one JSON object: who asked (the token id), from
where, the SQL, nodes, window, outcome and duration. By default it is logged
at `:info` level:

```text
[info] porthole.audit {"at":"2026-09-25T19:41:01.504Z","client":"oncall","remote_ip":"10.0.3.7","sql":"SELECT ...","nodes":["my_app@10.0.1.12"],"window_ms":null,"status":"ok","rows":2,"truncated":false,"error":null,"duration_ms":16}
```

To send records elsewhere, configure a function that receives each record:

```elixir
config :porthole, :audit, {MyOps.Audit, :record, []}
```

### Versions

Porthole needs Elixir 1.18+ and OTP 27+ on every node, including the
observed ones. A node on an older OTP answers with a clear error in
`errors` (the rest of the cluster still answers) and is never crashed by it.

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
