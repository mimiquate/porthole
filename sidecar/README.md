# Porthole sidecar

A deployable [Porthole](../README.md) server: it joins your cluster as a
hidden node (holding the distribution cookie) and serves Porthole's MCP tool
over HTTP. Agents get a URL and a token, never the cookie.

It is configured entirely by environment variables, follows the cluster as
nodes join and leave (seed nodes, their peers, DNS discovery), and refuses to
start without tokens or targets.

```console
$ MIX_ENV=prod mix release
$ RELEASE_DISTRIBUTION=name RELEASE_NODE=porthole@10.0.1.50 RELEASE_COOKIE="$RELEASE_COOKIE" \
  PORTHOLE_TOKENS="oncall:<sha256>" PORTHOLE_NODES="my_app@10.0.1.12" \
  _build/prod/rel/porthole_sidecar/bin/porthole_sidecar start
```

or with Docker, from the repository root:

```console
$ docker build -f sidecar/Dockerfile -t porthole-sidecar .
```

All variables, the Docker and Kubernetes setups, tokens and policies are in
[Setting up your team](../guides/team-setup.md#production). The variables are
also documented in `PortholeSidecar.Config`.
