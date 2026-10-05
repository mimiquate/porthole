defmodule Porthole.Kube do
  @moduledoc false
  # Drives `kubectl` for `mix porthole.k8s.up` and `mix porthole.k8s.down`: a
  # sidecar next to an app's Deployment, set up and torn down without touching
  # the app's own objects. What is not Kubernetes-specific lives in
  # Porthole.Trial.
  #
  # Everything `up` creates carries the label below, and `down` deletes by
  # that label: a Deployment, a Secret (tokens, and the cookie when the app
  # has no Secret for it) and a headless Service selecting the app's pods,
  # which gives the sidecar a DNS name to find them by.

  alias Porthole.Trial

  @label "porthole.mimiquate.com/trial"

  @type target :: %{
          name: String.t(),
          namespace: String.t(),
          selector: %{String.t() => String.t()},
          container: String.t(),
          cookie_ref: {String.t(), String.t()} | nil,
          ready: non_neg_integer()
        }

  @doc "The label on every object `up` creates (its value is the sidecar's name)."
  @spec label() :: String.t()
  def label, do: @label

  @doc "The `kubectl` executable: `PORTHOLE_KUBECTL`, or `kubectl` on the PATH."
  @spec executable() :: String.t()
  def executable do
    path = System.get_env("PORTHOLE_KUBECTL") || System.find_executable("kubectl")
    path || raise Mix.Error, message: "kubectl is not installed"
  end

  @doc "The `--namespace` and `--context` arguments for every call."
  @spec scope(keyword()) :: [String.t()]
  def scope(opts) do
    if(opts[:namespace], do: ["--namespace", opts[:namespace]], else: []) ++
      if opts[:context], do: ["--context", opts[:context]], else: []
  end

  @doc """
  The app's Deployment: its namespace, pod selector, the container running
  the release, where its cookie comes from, and how many pods are ready.
  """
  @spec target(String.t(), keyword()) :: target()
  def target(name, opts) do
    deployment =
      json!(
        scope(opts) ++ ["get", "deployment", name, "-o", "json"],
        "could not find the Deployment #{name}"
      )

    spec = deployment["spec"]
    containers = spec["template"]["spec"]["containers"]
    container = pick_container(containers, opts[:container], name)

    %{
      name: name,
      namespace: deployment["metadata"]["namespace"],
      selector: spec["selector"]["matchLabels"] || %{},
      container: container["name"],
      cookie_ref: cookie_ref(container, opts),
      ready: deployment["status"]["readyReplicas"] || 0
    }
  end

  defp pick_container(containers, nil, deployment) do
    # The container running a release sets RELEASE_* variables, usually.
    Enum.find(containers, hd(containers), fn container ->
      Enum.any?(container["env"] || [], &String.starts_with?(&1["name"], "RELEASE_"))
    end)
    |> tap(fn _ ->
      if length(containers) > 1 do
        Mix.shell().info("#{deployment} has several containers; pass --container to pick one.")
      end
    end)
  end

  defp pick_container(containers, name, deployment) do
    Enum.find(containers, &(&1["name"] == name)) ||
      Mix.raise("#{deployment} has no container named #{name}")
  end

  # Where the pod spec takes RELEASE_COOKIE from, when it is a Secret: then
  # the sidecar references the same Secret and the cookie is never read.
  defp cookie_ref(container, opts) do
    direct =
      Enum.find_value(container["env"] || [], fn
        %{"name" => "RELEASE_COOKIE", "valueFrom" => %{"secretKeyRef" => ref}} ->
          {ref["name"], ref["key"]}

        _ ->
          nil
      end)

    direct ||
      Enum.find_value(container["envFrom"] || [], fn
        %{"secretRef" => %{"name" => secret}} ->
          if "RELEASE_COOKIE" in secret_keys(secret, opts), do: {secret, "RELEASE_COOKIE"}

        _ ->
          nil
      end)
  end

  # Only the keys: the values are never printed.
  defp secret_keys(secret, opts) do
    template = "{{range $k, $v := .data}}{{$k}} {{end}}"

    case kubectl(scope(opts) ++ ["get", "secret", secret, "-o", "go-template=#{template}"]) do
      {keys, 0} -> String.split(keys)
      _ -> []
    end
  end

  @doc """
  Reads the running release's settings in one of the app's pods; the cookie
  only when `include_cookie` (when the app has no Secret for it).
  """
  @spec release(target(), keyword(), boolean()) :: Trial.release()
  def release(target, opts, include_cookie) do
    args =
      scope(opts) ++
        ["exec", "deployment/#{target.name}", "-c", target.container, "--"] ++
        Trial.inspect_argv(include_cookie)

    # stdout may hold the cookie: it is parsed, never shown.
    case System.cmd(executable(), args) do
      {output, 0} ->
        Trial.parse_release(output)

      {_output, status} ->
        Mix.raise("""
        could not inspect #{target.name}'s running release (kubectl exec exited with
        #{status}). Running it needs permission to exec into its pods, and a shell
        (sh) in its image.
        """)
    end
  end

  @doc """
  What the Deployment `name` is, as far as `up` and `down` are concerned:
  `:missing`, `:trial` (created by `up`), `:sidecar` (a Porthole sidecar set up
  some other way, never touched) or `:other`.
  """
  @spec sidecar_status(String.t(), keyword()) :: :missing | :trial | :sidecar | :other
  def sidecar_status(name, opts) do
    case kubectl(scope(opts) ++ ["get", "deployment", name, "-o", "json", "--ignore-not-found"]) do
      {"", 0} ->
        :missing

      {json, 0} ->
        deployment = JSON.decode!(json)
        containers = deployment["spec"]["template"]["spec"]["containers"]
        env = for c <- containers, var <- c["env"] || [], do: var["name"]

        cond do
          deployment["metadata"]["labels"][@label] == name -> :trial
          "PORTHOLE_PORT" in env or "PORTHOLE_TOKENS" in env -> :sidecar
          true -> :other
        end

      {_, _} ->
        Mix.raise("could not check whether #{name} exists")
    end
  end

  @doc """
  Checks that the current user may do what `up` needs, and says what is
  missing otherwise.
  """
  @spec check_permissions!(keyword(), boolean()) :: :ok
  def check_permissions!(opts, exec?) do
    needed =
      [
        {"create", "deployments.apps"},
        {"create", "secrets"},
        {"create", "services"},
        {"create", "pods/portforward"}
      ] ++ if(exec?, do: [{"create", "pods/exec"}], else: [])

    missing =
      for {verb, resource} <- needed,
          kubectl(scope(opts) ++ ["auth", "can-i", verb, resource]) |> elem(0) |> String.trim() !=
            "yes",
          do: "#{verb} #{resource}"

    if missing != [] do
      Mix.raise("you are not allowed to: #{Enum.join(missing, ", ")} (in this namespace)")
    end

    :ok
  end

  @doc "Creates or updates the objects in `manifest` (a List), read from stdin."
  @spec apply!(map(), keyword()) :: :ok
  def apply!(manifest, opts) do
    status =
      Trial.run_with_input(
        executable(),
        scope(opts) ++ ["apply", "-f", "-"],
        JSON.encode!(manifest)
      )

    if status != 0, do: Mix.raise("kubectl apply failed")
    :ok
  end

  @doc "Waits for the sidecar's Deployment to be rolled out."
  @spec rollout!(String.t(), keyword()) :: :ok
  def rollout!(name, opts) do
    args = scope(opts) ++ ["rollout", "status", "deployment/#{name}", "--timeout=180s"]

    case System.cmd(executable(), args, into: IO.stream(), stderr_to_stdout: true) do
      {_, 0} -> :ok
      {_, _} -> Mix.raise("#{name} did not start; see: kubectl describe deployment/#{name}")
    end
  end

  @doc "Deletes everything `up` created for `name`."
  @spec delete!(String.t(), keyword()) :: :ok
  def delete!(name, opts) do
    args = scope(opts) ++ ["delete", "deployment,service,secret", "-l", "#{@label}=#{name}"]

    case System.cmd(executable(), args, into: IO.stream(), stderr_to_stdout: true) do
      {_, 0} -> :ok
      {_, _} -> Mix.raise("could not delete #{name}")
    end
  end

  @doc """
  Opens a temporary `kubectl port-forward` to the sidecar and runs `fun` with
  the local port.
  """
  @spec with_port_forward(String.t(), keyword(), (pos_integer() -> result)) :: result
        when result: term()
  def with_port_forward(name, opts, fun) do
    Trial.with_tunnel(
      executable(),
      &(scope(opts) ++ ["port-forward", "deployment/#{name}", "#{&1}:4040"]),
      fun
    )
  end

  @doc "Whether the namespace has NetworkPolicies, which may block the sidecar."
  @spec network_policies?(keyword()) :: boolean()
  def network_policies?(opts) do
    case kubectl(scope(opts) ++ ["get", "networkpolicy", "-o", "name"]) do
      {out, 0} -> String.trim(out) != ""
      _ -> false
    end
  end

  @doc """
  The objects for the sidecar `name`, observing `target`: a Secret for its
  tokens (and the cookie, when copied), a headless Service selecting the
  app's pods, and the Deployment.
  """
  @spec manifest(String.t(), target(), Trial.release(), keyword()) :: map()
  def manifest(name, target, release, settings) do
    labels = %{@label => name, "app.kubernetes.io/managed-by" => "porthole"}
    meta = fn object_name -> %{name: object_name, namespace: target.namespace, labels: labels} end
    nodes_service = "#{name}-nodes"

    secret_data =
      %{"PORTHOLE_TOKENS" => settings[:tokens]}
      |> then(&if(target.cookie_ref, do: &1, else: Map.put(&1, "RELEASE_COOKIE", release.cookie)))

    {cookie_secret, cookie_key} = target.cookie_ref || {name, "RELEASE_COOKIE"}

    env =
      [
        %{name: "POD_IP", valueFrom: %{fieldRef: %{fieldPath: "status.podIP"}}},
        %{
          name: "RELEASE_COOKIE",
          valueFrom: %{secretKeyRef: %{name: cookie_secret, key: cookie_key}}
        },
        %{
          name: "PORTHOLE_TOKENS",
          valueFrom: %{secretKeyRef: %{name: name, key: "PORTHOLE_TOKENS"}}
        },
        %{
          name: "DNS_CLUSTER_QUERY",
          value: "#{nodes_service}.#{target.namespace}.svc.cluster.local"
        },
        %{name: "PORTHOLE_BIND", value: if(release.inet6, do: "::", else: "0.0.0.0")},
        %{name: Trial.trial_marker(), value: "true"}
      ] ++
        if(release.inet6, do: [%{name: "ERL_AFLAGS", value: "-proto_dist inet6_tcp"}], else: [])

    %{
      apiVersion: "v1",
      kind: "List",
      items: [
        %{apiVersion: "v1", kind: "Secret", metadata: meta.(name), stringData: secret_data},
        %{
          apiVersion: "v1",
          kind: "Service",
          metadata: meta.(nodes_service),
          spec: %{
            clusterIP: "None",
            selector: target.selector,
            # During an incident, pods that fail readiness are the interesting ones.
            publishNotReadyAddresses: true,
            ports: [%{name: "epmd", port: 4369}]
          }
        },
        %{
          apiVersion: "apps/v1",
          kind: "Deployment",
          metadata: meta.(name),
          spec: %{
            replicas: 1,
            selector: %{matchLabels: %{@label => name}},
            template: %{
              metadata: %{
                labels: labels,
                # Pods read the Secret only when they start: a new token must
                # roll the Deployment, or the running pod keeps the old one.
                annotations: %{
                  "porthole.mimiquate.com/tokens" =>
                    :sha256 |> :crypto.hash(settings[:tokens]) |> Base.encode16(case: :lower)
                }
              },
              spec: %{
                containers: [
                  %{
                    name: "porthole",
                    image: settings[:image],
                    ports: [%{name: "mcp", containerPort: 4040}],
                    env: env,
                    readinessProbe: %{httpGet: %{path: "/healthz", port: 4040}},
                    resources: %{
                      requests: %{cpu: "50m", memory: "128Mi"},
                      limits: %{memory: "256Mi"}
                    },
                    # The image's user (uid 1000, by name in the Dockerfile).
                    securityContext: %{
                      runAsNonRoot: true,
                      runAsUser: 1000,
                      allowPrivilegeEscalation: false
                    }
                  }
                ]
              }
            }
          }
        }
      ]
    }
  end

  defp json!(args, error) do
    case kubectl(args) do
      {output, 0} -> JSON.decode!(output)
      {_output, _status} -> Mix.raise(error)
    end
  end

  # stderr (warnings, errors) goes to the terminal, so stdout stays parseable.
  defp kubectl(args), do: System.cmd(executable(), args)
end
