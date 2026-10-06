# Security

## Reporting a vulnerability

Please report vulnerabilities privately, through GitHub: on this
repository's **Security** tab, choose **Report a vulnerability**. Do not
open a public issue for them.

Include what you found, how to reproduce it, and what an attacker could do
with it. We will acknowledge the report, keep you informed while we work on
a fix, and credit you when it is released, unless you prefer otherwise.

Fixes go into the latest release. Porthole is young (0.x): upgrade to the
latest version to get them.

## The security model, in short

Knowing what Porthole does and does not promise helps tell a vulnerability
from intended behavior. The full discussion is in
[Setting up your team](guides/team-setup.md#understand-the-trust-boundary).

**What Porthole guarantees**

- **Its tool is read-only.** Queries run in a throwaway in-memory SQLite
  database whose authorizer denies writes, `ATTACH`, `PRAGMA` and schema
  changes. The code that runs on observed nodes is Porthole's own, fixed
  when it is built, and only reads: agents send SQL, never code.
- **Clients cannot reach past their limits.** A token's policy narrows the
  server's, a request narrows the token's, and a request cannot add nodes
  beyond the ones the server queries.
- **Queries are bounded:** rows and bytes collected, rows returned, time,
  sampling windows, SQLite's memory, and the rate and concurrency of
  queries per client.
- **The HTTP server authenticates every request** with a per-client bearer
  token (only its SHA-256 hash is stored, compared in constant time),
  rejects browser requests (`Origin`) and bodies over 1 MB, and refuses to
  start without tokens.

**What it does not**

- **The node that runs queries holds the distribution cookie,** which
  grants full control of the cluster: Erlang has no read-only cookie.
  Whoever controls that node (the sidecar) controls the cluster, so it must
  be protected like any service holding cluster credentials.
- **Porthole is not a security boundary on its own.** It keeps the cookie
  away from agents only if it is their only route into production: an
  agent that also has shell access, `kubectl exec` or cloud credentials can
  go around it.
- **What agents can see is a deliberate grant.** Process and table names,
  labels, socket addresses and versions may reveal information about your
  system; scope tokens with policies.
- **Tokens are bearer credentials.** Outside a trusted network, serve the
  sidecar over HTTPS or reach it through a tunnel.
- The development endpoint (`auth: :localhost`) and the stdio server put no
  token between the agent and the node: they are for development only.
