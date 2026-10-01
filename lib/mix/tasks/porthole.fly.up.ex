defmodule Mix.Tasks.Porthole.Fly.Up do
  @shortdoc "Starts a Porthole sidecar next to an app on Fly.io, without touching the app"

  @moduledoc """
  Lets an agent observe an app running on Fly.io, without changing or
  redeploying the app:

      $ mix porthole.fly.up my-app

  It creates a separate Fly app for the sidecar (`my-app-porthole`) in the
  app's organization and region, and:

    1. reads the app's cookie and distribution settings from its running
       release (over `fly ssh console`) and stores the cookie as the
       sidecar's secret. The cookie is never printed or written to disk, and
       the agent never gets it;
    2. generates a token for you;
    3. deploys the sidecar;
    4. checks, through a temporary `fly proxy`, that it observes the app's
       nodes;
    5. prints the commands to open the tunnel and connect your agent.

  The app needs nothing from Porthole: any Elixir release on OTP 27+
  started with long names (`RELEASE_DISTRIBUTION=name`, as Phoenix apps on
  Fly.io are). `mix porthole.fly.down my-app` removes everything.

  Running it again is safe: it updates the same sidecar, issues a new token
  (the previous one stops working) and picks up the app's current cookie.
  An app whose cookie is generated at build time (no `RELEASE_COOKIE`
  secret) gets a new one on every deploy; run `up` again after deploying it.

  ## Options

    * `--name NAME` - the sidecar's Fly app (default: `<app>-porthole`).
    * `--client ID` - who the token is for, as the audit log shows it
      (default: your user name).
    * `--image IMAGE` - deploy a prebuilt sidecar image instead of building
      one from this checkout.

  Set `PORTHOLE_FLY` to use a `fly` executable that is not on the `PATH`.
  """

  use Mix.Task

  alias Porthole.Fly

  @switches [name: :string, client: :string, image: :string]

  @impl true
  def run(args) do
    case OptionParser.parse(args, strict: @switches) do
      {opts, [app], []} -> up(app, opts)
      _ -> Mix.raise("usage: mix porthole.fly.up APP [--name NAME] [--client ID] [--image IMAGE]")
    end
  end

  defp up(app_name, opts) do
    sidecar = opts[:name] || "#{app_name}-porthole"
    client = opts[:client] || System.get_env("USER") || "me"
    shell = Mix.shell()

    app = Fly.app(app_name)
    deploy = deploy_args(sidecar, app, opts[:image])

    shell.info("Reading #{app_name}'s distribution settings from its running release...")
    release = Fly.release(app_name)
    check_release!(app_name, release)
    dns = release.dns || "#{app_name}.internal"

    case Fly.sidecar_status(sidecar) do
      :missing ->
        shell.info("Creating #{sidecar} in #{app.org}...")
        Fly.run!(["apps", "create", sidecar, "--org", app.org], "could not create #{sidecar}")

      :sidecar ->
        shell.info("Updating #{sidecar}...")

      :other ->
        Mix.raise("#{sidecar} already exists and is not a Porthole sidecar; pick another --name")
    end

    token = Porthole.Auth.generate()

    Fly.import_secrets(sidecar, %{
      "RELEASE_COOKIE" => release.cookie,
      "PORTHOLE_TOKENS" => "#{client}:#{Porthole.Auth.hash(token)}"
    })

    shell.info("Deploying #{sidecar} (observing #{dns})...")
    Fly.run!(deploy ++ ["--env", "DNS_CLUSTER_QUERY=#{dns}"], "could not deploy #{sidecar}")

    shell.info("Checking what #{sidecar} observes...")

    case Fly.with_proxy(sidecar, &Fly.observed_nodes(&1, token)) do
      {:ok, nodes} ->
        shell.info("""

        #{sidecar} observes #{length(nodes)} node(s) of #{app_name}: #{Enum.join(nodes, ", ")}
        """)

      {:error, reason} ->
        shell.error("""

        #{sidecar} is deployed but observes no nodes yet: #{reason}
        Check its logs with: fly logs -a #{sidecar}
        """)
    end

    shell.info("""
    Open the tunnel, and keep it running while the agent works:

        fly proxy 4040:4040 -a #{sidecar}

    Connect your agent, e.g. Claude Code (this token is shown only once):

        claude mcp add --transport http #{sidecar} http://localhost:4040/ --header "Authorization: Bearer #{token}"

    Remove everything when you are done (the app is not touched):

        mix porthole.fly.down #{app_name}
    """)

    unless Fly.fixed_cookie?(app_name) do
      shell.info("""
      Note: #{app_name} has no RELEASE_COOKIE secret, so its cookie is generated when
      it is built and changes on every deploy. Run this command again after
      deploying #{app_name}.
      """)
    end
  end

  # The sidecar joins with long names over IPv6, as Phoenix apps on Fly.io
  # are set up (rel/env.sh.eex).
  defp check_release!(app, release) do
    cond do
      release.distribution != "name" ->
        Mix.raise("""
        #{app} does not run with long names (RELEASE_DISTRIBUTION=name), so the
        sidecar cannot join it. Phoenix apps on Fly.io set it in rel/env.sh.eex,
        along with RELEASE_NODE=<name>@${FLY_PRIVATE_IP}.
        """)

      not release.inet6 ->
        Mix.raise("""
        #{app} does not run distribution over IPv6, which Fly.io's private network
        requires: set ERL_AFLAGS="-proto_dist inet6_tcp" in its rel/env.sh.eex.
        """)

      true ->
        :ok
    end
  end

  defp deploy_args(sidecar, app, image) do
    root = Path.expand("../../..", __DIR__)
    config = Path.join(root, "sidecar/fly.toml")
    dockerfile = Path.join(root, "sidecar/Dockerfile")

    unless File.exists?(config) do
      Mix.raise("sidecar/fly.toml not found in #{root}: run this from a checkout of Porthole")
    end

    common = ["--config", config, "--app", sidecar, "--primary-region", app.region, "--ha=false"]

    cond do
      image -> ["deploy" | common] ++ ["--image", image]
      File.exists?(dockerfile) -> ["deploy", root | common] ++ ["--dockerfile", dockerfile]
      true -> Mix.raise("sidecar/Dockerfile not found in #{root}: pass --image")
    end
  end
end
