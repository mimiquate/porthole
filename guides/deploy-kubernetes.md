# Deploying the sidecar on Kubernetes

This guide runs the Porthole sidecar next to an Elixir app on Kubernetes, so
agents can query the app's live nodes without ever holding its cookie.
[Setting up your team](team-setup.md#production) explains the why; this is
the how.

There are two ways. Both leave your app as it is: it needs no Porthole
dependency, is not redeployed, and none of its objects are modified.

- **[Try it](#try-it-two-commands):** one command sets everything up, one
  removes it. Best for a first look at production.
- **[Set it up to stay](#set-it-up-to-stay):** a short manifest your team
  keeps with its other ones.

> **Status:** new. Verified on Amazon EKS (Kubernetes 1.34, October 2026)
> with a fresh Phoenix 1.8 app clustered by `dns_cluster` across two
> Graviton nodes: cookie in a Secret and cookie generated at build time,
> scaling 3 → 5 → 2 and a rolling deploy (the sidecar follows within
> seconds), NetworkPolicies enforced by the AWS VPC CNI (blocked, then the
> rule below), a user without exec permission (refused before anything is
> created), and two nodes of 100k processes (peak 513 MiB with four
> queries at once). Also verified on [kind](https://kind.sigs.k8s.io).
> GKE and AKS are untested: please open an issue if a step fails.

## What your app needs

The most common setup for clustered Elixir apps on Kubernetes:

- an Elixir release on OTP 27+, in a Deployment;
- long names with the pod's IP as host: `RELEASE_DISTRIBUTION=name` and
  `RELEASE_NODE=my_app@$(POD_IP)`, with `POD_IP` from the downward API (as
  the libcluster and `dns_cluster` setups do);
- a shell (`sh`) in its image, to read its settings (any Debian- or
  Alpine-based image; not distroless).

The cookie can come from a Secret (`RELEASE_COOKIE` from `secretKeyRef` or
`envFrom`) or be generated when the image was built. Both work.

## Try it: two commands

From a checkout of this repository, with `kubectl` pointing at the cluster:

```console
$ mix porthole.k8s.up my-app --namespace prod
```

`my-app` is your app's Deployment. Next to it, in the same namespace, it
creates a sidecar called `my-app-porthole`:

1. **The cookie.** When your pod spec takes `RELEASE_COOKIE` from a Secret,
   the sidecar references that same Secret, and the cookie is never read.
   Otherwise it is read from the running release (`kubectl exec`) into the
   sidecar's own Secret, without being printed. The agent never gets it.
2. It reads your app's distribution settings from a running pod and checks
   them, before creating anything.
3. It generates a token for you.
4. It creates a Deployment, a Secret and a headless Service that selects
   your app's pods, so the sidecar finds them by DNS. All three carry the
   label `porthole.mimiquate.com/trial`.
5. It checks, through a temporary `kubectl port-forward`, that the sidecar
   sees as many nodes as your app has ready pods.
6. It prints the two commands that remain:

```text
my-app-porthole observes 2 node(s) of my-app: my_app@10.0.3.17, my_app@10.0.5.22

Open the tunnel, and keep it running while the agent works:

    kubectl --namespace prod port-forward deployment/my-app-porthole 4040:4040

Connect your agent, e.g. Claude Code (this token is shown only once):

    claude mcp add --transport http my-app-porthole http://localhost:4040/ --header "Authorization: Bearer ph_…"
```

When you are done:

```console
$ mix porthole.k8s.down my-app --namespace prod
$ claude mcp remove my-app-porthole
```

`down` asks you to type the sidecar's name, then deletes the three objects
by their label. Run `claude mcp remove` from the folder where you added the
server.

Both commands only act on sidecars `up` created: a sidecar you set up some
other way (next section) is never updated or deleted by them. Running `up`
again updates the same sidecar and issues a new token (the previous one
stops working). If your cookie is generated at build time, it changes on
every deploy: run `up` again after deploying your app.

| Option | |
|---|---|
| `--namespace`, `--context` | As for `kubectl` (default: the current ones) |
| `--container` | The container running the release, when the pod has several |
| `--name` | The sidecar's name (default: `<deployment>-porthole`) |
| `--image` | The sidecar image (default: `ghcr.io/mimiquate/porthole-sidecar:latest`) |

**Permissions.** `up` checks first that you may create Deployments,
Secrets and Services, exec into pods and port-forward in the namespace, and
says what is missing.

## Troubleshooting

| What you see | Meaning |
|---|---|
| `does not run with long names` | Your app uses short names (or none): the sidecar cannot join it |
| `does not use the pod's IP as host` | Node names based on hostnames (`my_app@my-app-0.my-app-headless...`, common with StatefulSets) are not supported yet |
| `could not inspect ... (kubectl exec ...)` | No permission to exec into the pods, or no `sh` in the image |
| `observes only 1 of my-app's 2 instances` | A pod is restarting, or unreachable from the sidecar |
| `observes no nodes yet`, and a note about NetworkPolicies | A policy keeps the sidecar from your pods: see below |
| The sidecar or your app is `OOMKilled` right at start | See "Open-files limit" below |

**NetworkPolicies.** The sidecar connects to your pods on epmd (port 4369)
and on their distribution port, which is random unless your app pins it. If
a policy restricts ingress to your app, allow the sidecar (both the trial
and the permanent one carry this label):

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-porthole
  namespace: prod
spec:
  podSelector:
    matchLabels:
      app: my-app            # your app's pod labels
  policyTypes: [Ingress]
  ingress:
    - from:
        - podSelector:
            matchLabels:
              app.kubernetes.io/managed-by: porthole
```

**Open-files limit.** This is a known BEAM issue, not specific to
Porthole. The VM sizes its port table from the process's open-files limit,
and recent systemd (RHEL 9, Fedora, Arch), containerd 2.x and kind set that
limit to about a billion. The VM then reserves gigabytes at start, which a
memory limit turns into an `OOMKilled`; without a limit, it shows up as an
idle node using gigabytes ([RabbitMQ's write-up](https://www.rabbitmq.com/blog/2022/08/30/high-initial-memory-consumption-of-rabbitmq-nodes-on-centos-stream-9)).
The sidecar's release caps its port table (`+Q 65536`), wherever it runs.
If your own app's pods are affected, cap theirs: set `ERL_MAX_PORTS=65536`
on them (RabbitMQ recommends 50,000 to 100,000), or add `+Q 65536` to the
release's `rel/vm.args.eex`. Kubernetes has no per-pod setting for the
open-files limit itself. On EKS (Amazon Linux 2023 nodes) the limit is
65,536, so apps there are not affected.

## Set it up to stay

For a team that keeps using it, keep the sidecar in your manifests. You
need the Secret with your app's cookie (if your app has none, see
[step 1 of the production setup](team-setup.md#1-give-your-app-a-fixed-cookie))
and a token per person or agent:

```console
$ mix porthole.gen.token ana        # prints the token, and ana:<sha256>
$ kubectl -n prod create secret generic porthole --from-literal=tokens="ana:fd07d5…,ci:60303a…"
```

Then apply this manifest, with your namespace, your app's pod labels and
where its cookie is:

```yaml
apiVersion: v1
kind: Service
metadata:
  name: porthole-nodes
  namespace: prod
spec:
  clusterIP: None
  publishNotReadyAddresses: true   # pods failing readiness are often the interesting ones
  selector:
    app: my-app                    # your app's pod labels
  ports:
    - name: epmd
      port: 4369
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: porthole
  namespace: prod
  labels:
    app.kubernetes.io/name: porthole
    app.kubernetes.io/managed-by: porthole
spec:
  replicas: 1
  selector:
    matchLabels:
      app.kubernetes.io/name: porthole
  template:
    metadata:
      labels:
        app.kubernetes.io/name: porthole
        app.kubernetes.io/managed-by: porthole
    spec:
      containers:
        - name: porthole
          image: ghcr.io/mimiquate/porthole-sidecar:latest
          ports:
            - name: mcp
              containerPort: 4040
          env:
            - name: POD_IP
              valueFrom:
                fieldRef:
                  fieldPath: status.podIP
            - name: RELEASE_COOKIE
              valueFrom:
                secretKeyRef:
                  name: my-app-secrets   # where your app's cookie is
                  key: RELEASE_COOKIE
            - name: PORTHOLE_TOKENS
              valueFrom:
                secretKeyRef:
                  name: porthole
                  key: tokens
            - name: DNS_CLUSTER_QUERY
              value: porthole-nodes.prod.svc.cluster.local
          readinessProbe:
            httpGet:
              path: /healthz
              port: 4040
          resources:
            requests:
              cpu: 50m
              memory: 256Mi
            limits:
              memory: 1Gi              # queries briefly hold what they load (see max_bytes)
          securityContext:
            runAsNonRoot: true
            runAsUser: 1000        # the image's user
            allowPrivilegeEscalation: false
```

If your app runs distribution over IPv6, also set `ERL_AFLAGS` to
`-proto_dist inet6_tcp` and `PORTHOLE_BIND` to `::` on the sidecar. Within a
few seconds of starting, its logs list the nodes it found
(`kubectl -n prod logs deployment/porthole`).

Each person reaches it with a tunnel, and connects their agent once:

```console
$ kubectl -n prod port-forward deployment/porthole 4040:4040
$ claude mcp add --transport http porthole http://localhost:4040/ \
    --header "Authorization: Bearer ph_…"
```

To give or remove access, update the `porthole` Secret's `tokens` and
restart the sidecar (`kubectl -n prod rollout restart deployment/porthole`):
pods read Secrets only when they start.
