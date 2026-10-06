defmodule Porthole.Fly do
  @moduledoc false
  # Drives `fly` for `mix porthole.fly.up` and `mix porthole.fly.down`: a
  # sidecar for an app on Fly.io, set up and torn down without touching the
  # app. The cookie is read from the app's running release and goes straight
  # to the sidecar's secrets: it is never printed, logged or written to disk.
  # What is not Fly-specific lives in Porthole.Trial.

  alias Porthole.Trial

  # The sidecar's Fly config, embedded when Porthole is compiled, so `fly.up`
  # runs from an installed Porthole (Mix.install, an archive), not only from a
  # checkout. sidecar/fly.toml stays the single source; the Hex package ships it.
  @config_path Path.expand("../../sidecar/fly.toml", __DIR__)
  @external_resource @config_path
  @config File.read!(@config_path)

  @type app :: %{name: String.t(), org: String.t(), region: String.t(), machines: pos_integer()}

  @doc """
  Writes the sidecar's Fly config to a temporary file, runs `fun` with its
  path, and deletes it.
  """
  @spec with_config((Path.t() -> result)) :: result when result: term()
  def with_config(fun) do
    dir = Path.join(System.tmp_dir!(), "porthole-fly-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    path = Path.join(dir, "fly.toml")
    File.write!(path, @config)

    try do
      fun.(path)
    after
      File.rm_rf(dir)
    end
  end

  @doc "The `fly` executable: `PORTHOLE_FLY`, or `fly` on the PATH."
  @spec executable() :: String.t()
  def executable do
    path = System.get_env("PORTHOLE_FLY") || System.find_executable("fly")
    path || raise Mix.Error, message: "fly is not installed (https://fly.io/docs/flyctl/install/)"
  end

  @doc "The app's organization and region, and that it has a running machine."
  @spec app(String.t()) :: app()
  def app(name) do
    status = json!(["status", "-a", name, "--json"], "could not find the Fly app #{name}")
    started = for %{"state" => "started"} = m <- status["Machines"] || [], do: m

    if started == [] do
      Mix.raise("#{name} has no running machine to observe")
    end

    %{
      name: name,
      org: status["Organization"]["Slug"],
      region: hd(started)["region"],
      machines: length(started)
    }
  end

  @doc """
  Reads the running release's distribution settings, including its cookie,
  on one of the app's machines.
  """
  @spec release(String.t()) :: Trial.release()
  def release(app) do
    # stdout holds the cookie: it is parsed, never shown. stderr (connection
    # progress, errors) goes to the terminal.
    case System.cmd(executable(), ["ssh", "console", "-a", app, "-C", Trial.inspect_command()]) do
      {output, 0} ->
        release = Trial.parse_release(output)
        release.cookie || Mix.raise("could not read #{app}'s cookie")
        release

      {_output, status} ->
        Mix.raise("could not inspect #{app}'s running release (fly ssh exited with #{status})")
    end
  end

  @doc "Whether the app sets its cookie as a secret (otherwise it changes on every deploy)."
  @spec fixed_cookie?(String.t()) :: boolean()
  def fixed_cookie?(app) do
    secrets = json!(["secrets", "list", "-a", app, "--json"], "could not list #{app}'s secrets")
    Enum.any?(secrets, &(&1["name"] == "RELEASE_COOKIE"))
  end

  @doc """
  What the Fly app `name` is, as far as `up` and `down` are concerned:

    * `:missing` - it does not exist;
    * `:empty` - it exists but was never deployed (e.g. `up` failed midway);
    * `:trial` - a sidecar deployed by `mix porthole.fly.up`;
    * `:sidecar` - a sidecar set up some other way (a team's permanent one),
      which `up` and `down` must not touch;
    * `:other` - any other app.
  """
  @spec sidecar_status(String.t()) :: :missing | :empty | :trial | :sidecar | :other
  def sidecar_status(name) do
    apps = json!(["apps", "list", "--json"], "could not list your Fly apps")

    case Enum.find(apps, &(&1["Name"] == name)) do
      nil ->
        :missing

      %{"Deployed" => false} ->
        :empty

      _app ->
        case fly(["config", "show", "-a", name]) do
          {config, 0} ->
            env = JSON.decode!(config)["env"] || %{}

            cond do
              env[Trial.trial_marker()] -> :trial
              env["PORTHOLE_PORT"] -> :sidecar
              true -> :other
            end

          _ ->
            :other
        end
    end
  end

  @doc "Sets secrets from stdin, so their values never appear in a command line."
  @spec import_secrets(String.t(), %{String.t() => String.t()}) :: :ok
  def import_secrets(app, secrets) do
    input = Enum.map_join(secrets, "\n", fn {key, value} -> "#{key}=#{value}" end)

    status =
      Trial.run_with_input(executable(), ["secrets", "import", "--stage", "-a", app], input)

    if status != 0, do: Mix.raise("could not set the secrets of #{app}")
    :ok
  end

  @doc "Runs `fly` with output streamed to the terminal; raises on failure."
  @spec run!([String.t()], String.t()) :: :ok
  def run!(args, error) do
    case System.cmd(executable(), args, into: IO.stream(), stderr_to_stdout: true) do
      {_, 0} -> :ok
      {_, status} -> Mix.raise("#{error} (fly exited with #{status})")
    end
  end

  @doc """
  Opens a temporary `fly proxy` to the sidecar and runs `fun` with the local
  port, closing the proxy afterwards.
  """
  @spec with_proxy(String.t(), (pos_integer() -> result)) :: result when result: term()
  def with_proxy(app, fun),
    do: Trial.with_tunnel(executable(), &["proxy", "#{&1}:4040", "-a", app], fun)

  defp json!(args, error) do
    case fly(args) do
      {output, 0} -> JSON.decode!(output)
      {_output, _status} -> Mix.raise(error)
    end
  end

  # stderr (warnings, errors) goes to the terminal, so stdout stays parseable.
  defp fly(args), do: System.cmd(executable(), args)
end
