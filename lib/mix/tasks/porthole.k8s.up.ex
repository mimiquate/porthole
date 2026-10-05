defmodule Mix.Tasks.Porthole.K8s.Up do
  @shortdoc "Starts a Porthole sidecar next to an app on Kubernetes, without touching the app"

  @moduledoc """
  Lets an agent observe an app running on Kubernetes, without changing or
  redeploying it:

      $ mix porthole.k8s.up my-app --namespace shop

  `my-app` is the app's Deployment. Next to it, in the same namespace, it
  creates a sidecar (`my-app-porthole`), and:

    1. finds where the app's cookie comes from. When the pod spec takes
       `RELEASE_COOKIE` from a Secret, the sidecar references that same
       Secret, and the cookie is never read. Otherwise it is read from the
       running release (with `kubectl exec`) into the sidecar's own Secret;
       it is never printed or written to disk, and the agent never gets it;
    2. reads the app's distribution settings from a running pod;
    3. generates a token for you;
    4. creates the sidecar: a Deployment, a Secret and a headless Service
       that selects the app's pods (so the sidecar finds them by DNS). The
       app's own objects are not modified;
    5. checks, through a temporary `kubectl port-forward`, that it observes
       the app's nodes;
    6. prints the commands to open the tunnel and connect your agent.

  The app needs nothing from Porthole: any Elixir release on OTP 27+ started
  with long names whose host is the pod's IP (`RELEASE_DISTRIBUTION=name`,
  `RELEASE_NODE=my_app@$(POD_IP)`). `mix porthole.k8s.down my-app` removes
  everything; both commands only act on sidecars `up` created.

  Running it again is safe: it updates the same sidecar and issues a new
  token (the previous one stops working).

  ## Options

    * `--namespace NS`, `--context CTX` - as for `kubectl` (default: the
      current ones).
    * `--container NAME` - the app's container running the release, when the
      pod has several.
    * `--name NAME` - the sidecar's name (default: `<deployment>-porthole`).
    * `--client ID` - who the token is for, as the audit log shows it
      (default: your user name).
    * `--image IMAGE` - the sidecar image (default: the published
      `ghcr.io/mimiquate/porthole-sidecar:latest`).

  Set `PORTHOLE_KUBECTL` to use a `kubectl` that is not on the `PATH`.
  """

  use Mix.Task

  alias Porthole.{Kube, Trial}

  @switches [
    namespace: :string,
    context: :string,
    container: :string,
    name: :string,
    client: :string,
    image: :string
  ]

  @impl true
  def run(args) do
    case OptionParser.parse(args, strict: @switches, aliases: [n: :namespace]) do
      {opts, [deployment], []} -> up(deployment, opts)
      _ -> Mix.raise("usage: mix porthole.k8s.up DEPLOYMENT [--namespace NS] [options]")
    end
  end

  defp up(deployment, opts) do
    sidecar = opts[:name] || "#{deployment}-porthole"
    client = opts[:client] || System.get_env("USER") || "me"
    shell = Mix.shell()

    target = Kube.target(deployment, opts)
    if target.ready == 0, do: Mix.raise("#{deployment} has no ready pods to observe")
    opts = Keyword.put(opts, :namespace, target.namespace)

    case Kube.sidecar_status(sidecar, opts) do
      status when status in [:missing, :trial] ->
        :ok

      :sidecar ->
        Mix.raise("""
        #{sidecar} is a Porthole sidecar that was not started by this command (a
        permanent one, for instance). It is left alone: pick another --name.
        """)

      :other ->
        Mix.raise("a Deployment named #{sidecar} already exists; pick another --name")
    end

    Kube.check_permissions!(opts, true)

    shell.info("Reading #{deployment}'s distribution settings from a running pod...")
    release = Kube.release(target, opts, target.cookie_ref == nil)
    check_release!(deployment, release)

    if target.cookie_ref == nil and release.cookie == nil do
      Mix.raise("could not read #{deployment}'s cookie")
    end

    token = Porthole.Auth.generate()

    manifest =
      Kube.manifest(sidecar, target, release,
        tokens: "#{client}:#{Porthole.Auth.hash(token)}",
        image: opts[:image] || Trial.default_image()
      )

    shell.info("Creating #{sidecar} in #{target.namespace}...")
    Kube.apply!(manifest, opts)
    Kube.rollout!(sidecar, opts)

    shell.info("Checking what #{sidecar} observes...")

    observed =
      Kube.with_port_forward(sidecar, opts, &Trial.observed_nodes(&1, token, target.ready))

    case Trial.report(observed, sidecar, deployment, target.ready) do
      {:ok, message} ->
        shell.info("\n" <> message <> "\n")

      {:error, message} ->
        policies =
          if Kube.network_policies?(opts),
            do: """
            This namespace has NetworkPolicies: they must let #{sidecar}'s pod reach
            #{deployment}'s pods on epmd (4369) and on their distribution port.
            """,
            else: ""

        shell.error("""

        #{message}
        #{policies}Check its logs with: kubectl logs -n #{target.namespace} deployment/#{sidecar}
        """)
    end

    scope = Enum.join(Kube.scope(opts), " ")
    name_option = if opts[:name], do: " --name #{sidecar}", else: ""

    shell.info("""
    Open the tunnel, and keep it running while the agent works:

        kubectl #{scope} port-forward deployment/#{sidecar} 4040:4040

    Connect your agent, e.g. Claude Code (this token is shown only once):

        claude mcp add --transport http #{sidecar} http://localhost:4040/ --header "Authorization: Bearer #{token}"

    Remove everything when you are done (the app is not touched):

        mix porthole.k8s.down #{deployment} #{scope}#{name_option}
    """)

    if target.cookie_ref == nil do
      shell.info("""
      Note: #{deployment} does not take RELEASE_COOKIE from a Secret, so its cookie
      was copied into #{sidecar}'s own Secret. If the cookie is generated when the
      image is built, it changes on every deploy: run this command again after
      deploying #{deployment}.
      """)
    end
  end

  # The sidecar finds the app's pods by DNS (pod IPs) and connects to
  # <name>@<pod IP>, so the app must use long names with the pod IP as host.
  defp check_release!(deployment, release) do
    host = release.node && release.node |> String.split("@", parts: 2) |> List.last()

    cond do
      release.distribution != "name" ->
        Mix.raise("""
        #{deployment} does not run with long names (RELEASE_DISTRIBUTION=name), so
        the sidecar cannot join it. Clustered Elixir apps on Kubernetes usually set
        RELEASE_DISTRIBUTION=name and RELEASE_NODE=<name>@$(POD_IP).
        """)

      host == nil or not ip?(host) ->
        Mix.raise("""
        #{deployment}'s node name (#{release.node || "unset"}) does not use the pod's IP
        as host. The sidecar finds pods by IP, so it cannot connect to names based on
        hostnames yet.
        """)

      true ->
        :ok
    end
  end

  defp ip?(host), do: match?({:ok, _}, :inet.parse_address(String.to_charlist(host)))
end
