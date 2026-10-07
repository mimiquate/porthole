# Deploying the sidecar on Fly.io

This guide deploys the Porthole sidecar next to an app running on Fly.io, so
agents can query the app's live cluster without ever holding its cookie.
[Setting up your team](team-setup.md#production) explains the why; this is
the how.

There are two ways. Both leave your app as it is: it needs no Porthole
dependency and is not redeployed.

- **[Try it](#try-it-two-commands):** one command sets everything up, one
  removes it. Best for a first look at production.
- **[Set it up to stay](#set-it-up-to-stay):** the same sidecar, with
  every step in your hands, for a team that keeps using it.

## Try it: two commands

> **Status:** new. Used on two Phoenix apps on Fly.io (October 2026),
> including one without a fixed cookie and without Porthole as a
> dependency. Please open an issue if a step fails.

With `fly` logged in to your app's organization:

```console
$ mix archive.install hex porthole   # once
$ mix porthole.fly.up my-app
```

Your app needs nothing from Porthole: the archive only adds the `mix
porthole.*` commands to your machine, and `mix archive.uninstall porthole`
removes them.

It creates a separate Fly app, `my-app-porthole`, in your app's organization
and region, then:

1. reads your app's cookie from its running release (with `fly ssh
   console`) and stores it as the sidecar's secret. It is never printed,
   and the agent never gets it;
2. generates a token for you;
3. deploys the sidecar from the published image
   (`ghcr.io/mimiquate/porthole-sidecar`; run from a checkout of this
   repository, `--build` builds it from source instead) and checks that it
   sees your app's nodes;
4. prints the two commands that remain: the tunnel and the agent.

```text
my-app-porthole observes 2 node(s) of my-app: my-app-01J8X…@fdaa:0:…:2, my-app-01J8X…@fdaa:0:…:3

Open the tunnel, and keep it running while the agent works:

    fly proxy 4040:4040 -a my-app-porthole

Connect your agent, e.g. Claude Code (this token is shown only once):

    claude mcp add --transport http my-app-porthole http://localhost:4040/ --header "Authorization: Bearer ph_…"
```

When you are done:

```console
$ mix porthole.fly.down my-app
$ claude mcp remove my-app-porthole
```

`down` asks you to type the sidecar's name, then destroys it with its
secrets and tokens. Run `claude mcp remove` from the folder where you added
the server. `up` marks the sidecars it creates, and both commands only act
on those: a sidecar you set up to stay (next section) is never updated or
destroyed by them, even if its name matches. Use `--name` with both
commands when you already have a sidecar called `my-app-porthole`.

What your app needs: an Elixir release on OTP 27+, distributed with long
names over IPv6, which is how `fly launch` sets up Phoenix apps
(`RELEASE_DISTRIBUTION=name` and `ERL_AFLAGS="-proto_dist inet6_tcp"` in
`rel/env.sh.eex`). `up` checks this and says what is missing.

Running `up` again updates the same sidecar and issues a new token (the
previous one stops working). If your app has no `RELEASE_COOKIE` secret,
its cookie is generated when it is built and changes on every deploy, so
the sidecar loses access after your next deploy: run `up` again. `up` tells
you when this applies. To keep the sidecar, give your app a fixed cookie and
follow the next section.

## Set it up to stay

Responsibilities are split explicitly:

| Where | What |
|---|---|
| This repository | `sidecar/fly.toml` (generic: nothing app-specific), the published sidecar image (`ghcr.io/mimiquate/porthole-sidecar`) and this guide |
| The `fly` commands below | Everything specific to your app, passed as flags |
| Fly secrets on the sidecar app | `RELEASE_COOKIE` and `PORTHOLE_TOKENS` |

> **Status:** used in production (October 2026) for a Phoenix app on Fly.io
> whose node names change with every deploy (`app-<image id>@<IPv6>`): the
> sidecar found its nodes from the DNS name alone, and agents query it
> through `fly proxy`. If a step does not behave as described, please open
> an issue.

### Values you need

The commands use these placeholders. Replace them with your own values:

| Placeholder | Example | Where it comes from |
|---|---|---|
| `my-app-porthole` | `shop-porthole` | A name for the sidecar's Fly app |
| `ewr` | `ewr` | A Fly region, usually your app's (`primary_region` in its `fly.toml`) |
| `my-app.internal` | `shop.internal` | Your app's `DNS_CLUSTER_QUERY` (Phoenix apps on Fly: `<fly app>.internal`) |

### Before you start

1. **Your app uses a fixed cookie,** set as a `RELEASE_COOKIE` Fly secret.
   Without one, `mix release` generates a new cookie on every build and the
   sidecar cannot join. See [step 1 of the production
   setup](team-setup.md#1-give-your-app-a-fixed-cookie).
2. **You have a checkout of this repository.** All commands run from its
   root. Your app does not need Porthole as a dependency, and it is not
   redeployed: the sidecar sends Porthole's read-only collection code to
   your nodes with each query.
3. **`fly` is installed and logged in** to the organization that owns your
   app.

### 1. Create the sidecar app and its secrets

```console
$ fly apps create my-app-porthole       # in the same organization as your app
$ mix porthole.gen.token ana            # once per person or agent
```

`gen.token` prints a token (give it to that person; it is shown once) and
its fingerprint (`ana:fd07d5…`). Then set the secrets. Read the cookie
without echoing it, so it stays out of your shell history:

```console
$ read -rs RELEASE_COOKIE               # paste your app's cookie, press Enter
$ fly secrets set --stage -a my-app-porthole \
    RELEASE_COOKIE="$RELEASE_COOKIE" \
    PORTHOLE_TOKENS="ana:fd07d5…,ci:60303a…"
$ unset RELEASE_COOKIE
```

`--stage` stores the secrets without deploying; the next step deploys.

### 2. Deploy

```console
$ fly deploy \
    --config sidecar/fly.toml \
    --image ghcr.io/mimiquate/porthole-sidecar:latest \
    --app my-app-porthole \
    --primary-region ewr \
    --ha=false \
    --env DNS_CLUSTER_QUERY=my-app.internal
```

| Flag | Why |
|---|---|
| `--config sidecar/fly.toml` | The generic config: IPv6, the listener, a health check, no public service |
| `--image …` | The published sidecar image (amd64 and arm64, built from `main`; versioned tags such as `:0.1.0` come with releases). Its Elixir/OTP need not match your app's |
| `--app`, `--primary-region` | Your sidecar app and its region |
| `--ha=false` | One machine: the sidecar holds no state, and a second one adds nothing |
| `--env DNS_CLUSTER_QUERY=…` | How the sidecar finds your app's nodes |

Every later deploy (after a Porthole upgrade, for instance) is the same
command, with the same values.

**To build the sidecar yourself** instead (to try local changes, or to pin
Elixir/OTP), build from this repository with its Dockerfile:

```console
$ fly deploy . --dockerfile sidecar/Dockerfile \
    --config sidecar/fly.toml --app my-app-porthole --primary-region ewr --ha=false \
    --build-arg ELIXIR_VERSION=1.18.3 --build-arg OTP_VERSION=27.3.3 \
    --build-arg DEBIAN_VERSION=bookworm-20260610-slim \
    --env DNS_CLUSTER_QUERY=my-app.internal
```

The three build arguments must form an existing
[`hexpm/elixir` image tag](https://hub.docker.com/r/hexpm/elixir/tags).

### 3. Check it

```console
$ fly logs -a my-app-porthole
```

Within a few seconds of starting, it logs the nodes it found:

```text
Porthole sidecar observing: my-app-01J8X…@fdaa:0:…:2, my-app-01J8X…@fdaa:0:…:3
```

| What you see | Meaning |
|---|---|
| `observing: …`, with every app machine | Ready |
| `cannot connect to: …` | Almost always `RELEASE_COOKIE` differs from the app's (see below) |
| `found no nodes to observe` once, right after the sidecar starts, then `observing: …` | Harmless: Fly's internal DNS was not answering yet |
| `found no nodes to observe` that persists | `DNS_CLUSTER_QUERY` is wrong, or the app runs in another organization |
| Query errors saying `this node does not run Elixir` or `Porthole needs OTP 27+` | The observed nodes are not an Elixir app on OTP 27+ |

**Checking the cookie.** Fly's secret digests come from the values, so
`RELEASE_COOKIE` must show **the same digest** in both:

```console
$ fly secrets list -a my-app
$ fly secrets list -a my-app-porthole
```

When they differ, the app's logs show the sidecar being turned away
(`Connection attempt from node … rejected. Invalid challenge reply.`). Copy
the app's exact value to the sidecar without displaying it (this also
restarts the sidecar):

```console
$ fly secrets set -a my-app-porthole \
    RELEASE_COOKIE="$(fly ssh console -a my-app -C 'printenv RELEASE_COOKIE' | tail -1 | tr -d '\r\n')"
```

`fly checks list -a my-app-porthole` shows the `/healthz` check.

### 4. Connect an agent

Open a tunnel to the sidecar (nothing is exposed publicly) and keep it
running while the agent works:

```console
$ fly proxy 4040:4040 -a my-app-porthole
```

Connect the agent once, with the person's token, e.g. for Claude Code:

```console
$ claude mcp add --transport http my-app-porthole http://localhost:4040/ \
    --header "Authorization: Bearer ph_…"
```

and pre-approve the tool, which is read-only: `/permissions`, allow
`mcp__my-app-porthole__query`. Then ask, for example: *"How many processes
run on each node, and what uses the most memory?"*

Every query is recorded in the sidecar's logs (`porthole.audit` lines): who
asked, what, and the outcome.

### Day to day

| Task | How |
|---|---|
| Give someone access | `mix porthole.gen.token <name>`, then `fly secrets set -a my-app-porthole PORTHOLE_TOKENS="<all entries>"` (setting a secret restarts the sidecar) |
| Remove someone's access | Set `PORTHOLE_TOKENS` without their entry |
| Remove Porthole | `fly apps destroy my-app-porthole`: nothing was installed in the app |
| Deploy or scale the app | Nothing: the sidecar finds new machines within seconds |
| Upgrade Porthole | Run step 2 again (it pulls the latest image); the app is not involved |
| Rotate the cookie | Set the new `RELEASE_COOKIE` on both apps |
| Review what agents looked at | `fly logs -a my-app-porthole`, `porthole.audit` lines |
