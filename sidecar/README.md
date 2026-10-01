# Porthole sidecar

A deployable [Porthole](../README.md) server: it joins your cluster as a
hidden node (holding the distribution cookie) and serves Porthole's MCP tool
over HTTP. Agents get a URL and a token, never the cookie.

It is configured entirely by environment variables and follows the cluster
as nodes join and leave. You tell it where your app runs, not what its nodes
are called: usually the same `DNS_CLUSTER_QUERY` your app clusters with.

```console
$ MIX_ENV=prod mix release
$ RELEASE_COOKIE="$RELEASE_COOKIE" PORTHOLE_TOKENS="oncall:<sha256>" DNS_CLUSTER_QUERY="my-app.internal" \
  _build/prod/rel/porthole_sidecar/bin/porthole_sidecar start
```

or with Docker, from the repository root:

```console
$ docker build -f sidecar/Dockerfile -t porthole-sidecar .
```

All variables, the Docker and Kubernetes setups, tokens and policies are in
[Setting up your team](../guides/team-setup.md#production). On Fly.io, use
`fly.toml` here and follow [Deploying the sidecar on Fly.io](../guides/deploy-fly.md). The variables are
also documented in `PortholeSidecar.Config`.
