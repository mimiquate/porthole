# Changelog

## 0.1.1 - 2026-10-07

- `fly.up` / `k8s.up` reopen the temporary tunnel they check the sidecar
  through if it exits (a dropped connection ends `fly proxy` and
  `kubectl port-forward`), instead of failing with "could not reach the
  sidecar" while the sidecar is fine.
- Docs: the archive is installed per Elixir version (asdf and mise keep one
  Mix home per version).

## 0.1.0 - 2026-10-07

The first release. Porthole lets coding agents inspect a live Erlang/Elixir
system with read-only SQL, without installing anything in the app.

### What it does

- **Six tables** over a live system: `processes`, `supervisors`, `ets_tables`,
  `ports`, `applications` and `system`, with a `node` column for clusters,
  and `_delta` columns over a sampling window (`window_ms`).
- **One SQL query** per question (joins, aggregates, recursive CTEs), run
  in a throwaway in-memory SQLite database. A read-only authorizer denies
  writes, `ATTACH`, `PRAGMA` and schema changes.
- **Nothing to install in the observed app.** Porthole sends its own
  read-only collection code over Erlang distribution and the node evaluates
  it with OTP's `:erl_eval`: any Elixir app on OTP 27+ can be observed as it
  runs.
- **Bounded and gentle on production nodes:** collection runs at low
  priority with a deadline enforced on the node itself; rows, bytes, result
  rows, time, sampling windows, SQLite's memory, concurrency and the rate of
  queries per client are capped, and every cut is reported in `notes`.

### How to use it

- **Try it on production:** `mix porthole.fly.up APP` (Fly.io) or
  `mix porthole.k8s.up DEPLOYMENT` (Kubernetes) starts a sidecar next to an
  app without changing it; `fly.down` / `k8s.down` remove it. Install the
  commands with `mix archive.install hex porthole`.
- **Keep it:** the sidecar (`ghcr.io/mimiquate/porthole-sidecar`, or the
  `sidecar/` release) serves MCP over HTTP with per-client bearer tokens,
  per-token policies and an audit log. See the Fly.io and Kubernetes guides.
- **In development:** an in-app MCP endpoint (`Porthole.MCP.Plug`,
  `auth: :localhost`), MCP over stdio (`mix porthole.mcp`), and
  `mix porthole.query` / `Porthole.query/2`.
- **`mix porthole.doctor`** checks every node and says what to fix.

### Verified

- Fly.io, on two Phoenix apps (one without a fixed cookie).
- Amazon EKS (Kubernetes 1.34, Graviton nodes) and kind.
- OTP 27 to 29 (a sidecar on one observes apps on the others), Elixir 1.18
  to 1.20.
- Blind agent evals on an app with nine planted problems: 9/9, 7/9 and 8/9
  in three runs, with no wrong claims ([evals](evals/README.md)).

### Known limits

- Only the `observe` capability tier is implemented; tracing is planned.
- Node names must use long names; on Kubernetes, the pod IP as host
  (StatefulSet-style hostnames are not supported yet).
- On an overloaded node, large tables can time out: collection only uses
  spare CPU, by design. `system` stays fast.
- `fly.up` / `k8s.up` need a Unix shell (WSL on Windows).
- GKE and AKS are untested.
