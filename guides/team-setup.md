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

In development, mount Porthole inside your app and point the agent at it. No
named node, cookie, sidecar or token is needed.

**1. Add the dependencies for development:**

```elixir
{:porthole, "~> 0.1"},
{:exqlite, "~> 0.41", only: :dev}
```

**2. Mount the endpoint in your router, in development only:**

```elixir
# lib/my_app_web/router.ex
if Mix.env() == :dev do
  forward "/porthole", Porthole.MCP.Plug, auth: :localhost
end
```

Put it outside any `pipe_through` (the endpoint is not a browser page).
`auth: :localhost` accepts requests only straight from your machine: other
addresses, proxied requests and browsers are rejected, and a warning is
logged when the router compiles. Never enable it in production.

**3. Connect the agent**, e.g. for Claude Code:

```console
$ claude mcp add --transport http porthole http://localhost:4000/porthole
```

or commit it for the whole team in `.mcp.json`:

```json
{
  "mcpServers": {
    "porthole": {"type": "http", "url": "http://localhost:4000/porthole"}
  }
}
```

That's it: with `mix phx.server` running, the agent has a `query` tool whose
description includes the full schema.

### Without Phoenix

Serve the same plug with Bandit, in development only, e.g. in your
application's children:

```elixir
children =
  if Mix.env() == :dev,
    do: [{Bandit, plug: {Porthole.MCP.Plug, auth: :localhost}, port: 4040}],
    else: []
```

and connect the agent to `http://localhost:4040/`.

### Over distribution instead

To inspect a node started separately (or a non-HTTP app), start it as a named
node and let the MCP server join it over stdio:

```console
$ iex --sname my_app@localhost --cookie dev -S mix
```

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

Run `mix compile` before the agent starts: this MCP server speaks over
stdout, and compiler output there would corrupt the protocol. The dev cookie
ends up next to the agent, which is fine in development and exactly what the
[production setup](#production) avoids.

### Checking the setup

`mix porthole.doctor` checks that each node can be observed: reachable,
Porthole loaded, same version, OTP 27+, and a real collection. It explains
what to fix when something is off:

```console
$ mix porthole.doctor --connect my_app@localhost --cookie dev
✓ my_app@localhost  porthole 0.1.0, OTP 29, Elixir 1.20.4, latency 0ms, collection 5ms
```

To try Porthole without an app, `mix porthole.query --demo "..."` runs
queries against a small built-in app with planted problems.

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

**Pre-approve the tool.** It is read-only, so asking for permission on every
query only adds friction, and in our runs Claude Code's auto-mode check
intermittently failed on it. Allow it for the whole team in the project's
`.claude/settings.json` (use the name you registered the server under):

```json
{"permissions": {"allow": ["mcp__porthole__query"]}}
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
sidecar is deployed separately, inside the cluster's private network, so it
keeps working when the app is struggling (which is when you need it) and
the app carries no extra NIF, port or process.

Setting it up for the first time takes six steps, in this order.

### 1. Give your app a fixed cookie

The sidecar joins your cluster with the same cookie as your app, so the
cookie has to be a value you control. **If your app does not set one, `mix
release` generates a random cookie at build time**: your servers share it
(they come from the same build), but it changes on every deploy and nothing
outside the build knows it.

To check: if your app's cookie comes from a `RELEASE_COOKIE` secret (or a
fixed `cookie:` in the release config), it is fixed; otherwise it is
generated. In a remote console, `Node.get_cookie()` shows the current value.

To fix it, generate a value once and store it as a secret that both the app
and the sidecar receive as `RELEASE_COOKIE`:

```console
$ mix phx.gen.secret 32      # or: openssl rand -base64 32
```

For example `fly secrets set RELEASE_COOKIE=...` on Fly.io, or a Kubernetes
Secret mounted as an environment variable in both Deployments. Many teams
already do this so that clustering survives rolling deploys, when servers
from two builds run side by side.

### 2. Add Porthole to your app

Add `{:porthole, "~> 0.1"}` to your app's dependencies and deploy. It adds no
processes, configuration or native code to your servers; it makes the
read-only collectors available to the sidecar.

### 3. Create a token per client

Each agent, team or person gets its own token, so the audit log says who
asked and each can be revoked on its own:

No server is needed for this: tokens are generated on your machine, in your
app's repository (the task comes with the dependency).

```console
$ mix porthole.gen.token oncall
Token for oncall (give this to the client; it is shown only once):

    ph_EXAMPLE-not-a-real-token

Server configuration, either in config (one entry per client in the list):

    config :porthole, :tokens, [
      [id: "oncall", sha256: "fd07d512979f51c4..."]
    ]

or, for the sidecar, in PORTHOLE_TOKENS (comma separated):

    PORTHOLE_TOKENS=oncall:fd07d512979f51c4...

Connect an agent, e.g. Claude Code (the URL is known once the sidecar is
reachable, see step 5):

    claude mcp add --transport http porthole <SIDECAR_URL> --header "Authorization: Bearer ph_EXAMPLE-not-a-real-token"
```

Only the hash goes in the server's configuration. A token can carry a policy
that narrows what that client sees (in a config file, `PORTHOLE_CONFIG` for
the sidecar):

```elixir
config :porthole, :tokens, [
  [id: "oncall", sha256: "fd07d5..."],
  [id: "ci-deploy-check", sha256: "60303a...", policy: [max_result_rows: 50]],
  [id: "contractor", sha256: "b5bb9d...", policy: [nodes: [:"my_app@staging-1"]]]
]
```

Removing an entry revokes the token.

### 4. Run the sidecar

The sidecar is a small application in [`sidecar/`](https://github.com/mimiquate/porthole/tree/main/sidecar),
configured entirely by environment variables and shipped as a release or a
Docker image. It joins your cluster as a hidden node (so it does not appear
in your nodes' `Node.list/0`) and keeps following it: nodes that join or
leave are picked up within seconds, without a restart.

**You tell it where your app runs, not what its nodes are called.** It asks
each host's Erlang port mapper (epmd, port 4369, which your cluster already
uses) which nodes live there. Addresses that change on every deploy, and
node names that include a release id, are handled for you.

In the common case the sidecar needs three variables, all of which you
already have:

| Variable | Where it comes from |
|---|---|
| `RELEASE_COOKIE` | The same secret as your app (step 1) |
| `PORTHOLE_TOKENS` | `mix porthole.gen.token` (step 3) |
| `DNS_CLUSTER_QUERY` | The same value your app clusters with (Phoenix apps have it, e.g. `my-app.internal` on Fly.io or the headless Service name on Kubernetes) |

```console
$ cd sidecar && MIX_ENV=prod mix release
$ RELEASE_COOKIE="$RELEASE_COOKIE" PORTHOLE_TOKENS="oncall:fd07d5..." DNS_CLUSTER_QUERY="my-app.internal" \
  _build/prod/rel/porthole_sidecar/bin/porthole_sidecar start
```

The sidecar names itself `porthole@<its IP>` (from `POD_IP`,
`FLY_PRIVATE_IP`, or the host's address) and uses long names, as clusters
that find each other by address do.

**If your app does not cluster through DNS**, list where it runs instead:
`PORTHOLE_NODES=10.0.1.12,10.0.1.13` (hosts), or full node names if you know
them (`shop@10.0.1.12`). One reachable node is enough when it is connected
to the rest: the sidecar follows its peers.

All variables:

| Variable | Meaning | Default |
|---|---|---|
| `DNS_CLUSTER_QUERY` | DNS name(s) to find your app's hosts | |
| `PORTHOLE_NODES` | Hosts or full node names, comma separated | |
| `PORTHOLE_DISCOVERY` | `dns:<name>`, when your app uses another variable than `DNS_CLUSTER_QUERY` | |
| `PORTHOLE_NODE_PREFIX` | Only observe nodes whose name starts with this (if hosts run other Erlang nodes) | all |
| `PORTHOLE_FOLLOW_PEERS` | Also observe every node the found nodes are connected to | `true` |
| `PORTHOLE_TOKENS` | Clients, `id:sha256,...` | required |
| `PORTHOLE_PORT` / `PORTHOLE_BIND` | Where to listen | `4040` / `0.0.0.0` |
| `PORTHOLE_CERTFILE` / `PORTHOLE_KEYFILE` | Serve HTTPS | |
| `PORTHOLE_CONFIG` | An Elixir config file for per-token policies and the environment policy | |
| `RELEASE_NODE` / `RELEASE_DISTRIBUTION` | Override the sidecar's own name / name type | `porthole@<IP>` / `name` |

The sidecar refuses to start without tokens or a place to look, and it logs
which nodes it observes, which it cannot connect to, and when it finds none.
Remote consoles and `rpc` calls (`rem-*`, `rpc-*` nodes) are never observed. `GET /healthz` answers `200 ok`
for liveness checks, and `mix porthole.doctor` checks each node in detail.

**Fly.io.** [Deploying the sidecar on Fly.io](deploy-fly.md) has the exact
commands, from creating the app to connecting an agent.

**Docker.** Build from the repository root:

```console
$ docker build -f sidecar/Dockerfile -t porthole-sidecar .
$ docker run -p 4040:4040 -e RELEASE_COOKIE="$RELEASE_COOKIE" \
    -e PORTHOLE_TOKENS="oncall:fd07d5..." -e DNS_CLUSTER_QUERY="my-app.internal" \
    porthole-sidecar
```

Match the image's Elixir/OTP to your cluster (`--build-arg OTP_VERSION=...`).
On IPv6-only networks (such as Fly.io's), also pass
`ERL_AFLAGS="-proto_dist inet6_tcp"`, as your app does.

**Kubernetes** (sketch, not yet tested on a cluster): run the sidecar as a
Deployment in the same namespace, with the app's headless Service as the
DNS query and the pod IP as its address:

```yaml
env:
  - name: POD_IP
    valueFrom: {fieldRef: {fieldPath: status.podIP}}
  - name: RELEASE_COOKIE
    valueFrom: {secretKeyRef: {name: my-app, key: cookie}}
  - name: DNS_CLUSTER_QUERY
    value: my-app-headless.default.svc.cluster.local
  - name: PORTHOLE_TOKENS
    valueFrom: {secretKeyRef: {name: porthole, key: tokens}}
```

**Without the packaged sidecar**, any project that depends on `porthole`,
`exqlite`, `plug` and `bandit` can run the same server with
`mix porthole.server --connect my_app@10.0.1.12 --cookie "$RELEASE_COOKIE"
--all-nodes --bind 0.0.0.0`, or add `{Porthole.Server, ...}` to its
supervision tree. The server refuses to start without at least one token,
listens on `127.0.0.1` unless told otherwise, and serves HTTPS with
`--certfile`/`--keyfile`. Without those, terminate TLS in front of it
(ingress, load balancer): tokens must not travel in clear text outside a
trusted network.

### 5. Make the sidecar reachable for agents

The agent's machine must reach the sidecar's port (4040 by default). How is
up to you; the address you end up with is the sidecar URL:

| How | Sidecar URL |
|---|---|
| Nothing exposed: each person opens a tunnel when needed, e.g. `kubectl port-forward deploy/porthole 4040:4040` or `fly proxy 4040:4040 -a my-porthole` | `http://localhost:4040/` |
| An internal hostname behind your load balancer or ingress, over VPN or the office network | `https://porthole.mycompany.internal/` |
| A private network address | `https://10.0.1.50:4040/` |

Tunnels are the simplest start: nothing is exposed and the traffic is
encrypted by the tunnel. Avoid exposing the sidecar on the public internet;
it is authenticated, but the safest sidecar is one only your network can
reach. Anywhere outside a trusted network, use HTTPS (tokens are bearer
credentials).

### 6. Connect the agent

With the token from step 3 and the URL from step 5, e.g. for Claude Code:

```console
$ claude mcp add --transport http porthole http://localhost:4040/ \
    --header "Authorization: Bearer ph_EXAMPLE-not-a-real-token"
```

For people added later, when the URL is known, `mix porthole.gen.token ana
--url <SIDECAR_URL>` prints this command ready to paste. Other MCP clients
that support the Streamable HTTP transport with custom headers take the same
URL and header.

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
  # What one query may collect and return.
  max_rows: 50_000,          # rows per table, per node
  max_bytes: 10_000_000,     # bytes per table, per node
  max_result_rows: 200,
  max_window_ms: 30_000,
  timeout_ms: 10_000,        # collection deadline (enforced on each node) and SQL time
  # How much load agents may put on the cluster.
  queries_per_minute: 60,    # per client (token)
  max_concurrent: 4          # queries running at once, across all clients
```

The values above are the defaults. A token's `policy:` can lower any of them
for that client, for example `queries_per_minute: 10` for a CI job.

When a limit is hit, the query is not silently degraded:

- **Collection limits** (`max_rows`, `max_bytes`) cut the rows and the result
  says so in `notes`, e.g. *"processes on app@host: collection stopped at
  10000000 bytes, aggregates are incomplete"*.
- **Load limits** reject the query with an error the agent can act on:
  `rate_limited` (*"60 queries per minute for this client; retry in 12s"*) or
  `busy` (*"4 queries are already running on this node; retry in a few
  seconds"*). Rejected queries do not count toward the rate.

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
tab costs for one refresh. Nothing runs between queries, and observed nodes
run no Porthole processes at all.

On each observed node, collection:

- runs at **low priority**, so under load the application wins and Porthole
  waits, never the other way around;
- has a **deadline enforced on the node itself**: past `timeout_ms` (plus the
  window) the work is stopped there, not merely abandoned by the caller
  (Erlang's `:erpc` does not stop remote work when the caller times out);
- is **capped** by `max_rows` and `max_bytes` per table.

Across the cluster, `max_concurrent` and `queries_per_minute` bound how much
collection agents can trigger.

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
