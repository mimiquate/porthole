defmodule Porthole.Fly do
  @moduledoc false
  # Drives `fly` for `mix porthole.fly.up` and `mix porthole.fly.down`: a
  # sidecar for an app on Fly.io, set up and torn down without touching the
  # app. The cookie is read from the app's running release and goes straight
  # to the sidecar's secrets: it is never printed, logged or written to disk.

  # Runs on an app machine (through `fly ssh console`): prints the settings
  # of the running release from its own environment, so it works whether the
  # cookie is a fixed secret or was generated at build time. Remote consoles
  # and rpc calls (RELEASE_COMMAND=remote/rpc) are skipped.
  @inspect_script ~S"""
  for p in /proc/[0-9]*; do
    case "$(tr '\0' ' ' < "$p/cmdline" 2>/dev/null)" in *beam.smp*) ;; *) continue ;; esac
    env="$(tr '\0' '\n' < "$p/environ" 2>/dev/null)" || continue
    case "$(printf '%s\n' "$env" | sed -n 's/^RELEASE_COMMAND=//p')" in start|start_iex|daemon|daemon_iex) ;; *) continue ;; esac
    printf '%s\n' "$env" | grep -E '^(RELEASE_COOKIE|RELEASE_DISTRIBUTION|RELEASE_NODE|ERL_AFLAGS|DNS_CLUSTER_QUERY)='
    exit 0
  done
  echo "no running Elixir release found on this machine" >&2
  exit 3
  """

  @type app :: %{name: String.t(), org: String.t(), region: String.t()}
  @type release :: %{
          cookie: String.t(),
          distribution: String.t() | nil,
          node: String.t() | nil,
          inet6: boolean(),
          dns: String.t() | nil
        }

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

    %{name: name, org: status["Organization"]["Slug"], region: hd(started)["region"]}
  end

  @doc """
  Reads the running release's distribution settings, including its cookie,
  on one of the app's machines.
  """
  @spec release(String.t()) :: release()
  def release(app) do
    script = Base.encode64(@inspect_script)
    command = "sh -c 'echo #{script} | base64 -d | sh'"

    # stdout holds the cookie: it is parsed, never shown. stderr (connection
    # progress, errors) goes to the terminal.
    case System.cmd(executable(), ["ssh", "console", "-a", app, "-C", command]) do
      {output, 0} ->
        vars =
          for line <- String.split(output, ["\r\n", "\n"]),
              [key, value] <- [String.split(line, "=", parts: 2)],
              into: %{},
              do: {key, value}

        cookie = vars["RELEASE_COOKIE"] || Mix.raise("could not read #{app}'s cookie")

        %{
          cookie: cookie,
          distribution: vars["RELEASE_DISTRIBUTION"],
          node: vars["RELEASE_NODE"],
          inet6: String.contains?(vars["ERL_AFLAGS"] || "", "inet6_tcp"),
          dns: vars["DNS_CLUSTER_QUERY"]
        }

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

  @doc "The environment variable that marks sidecars deployed by `mix porthole.fly.up`."
  @spec trial_marker() :: String.t()
  def trial_marker, do: "PORTHOLE_TRIAL"

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
              env[trial_marker()] -> :trial
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

    {_, status} =
      System.cmd(
        "sh",
        [
          "-c",
          ~S(printf '%s\n' "$PORTHOLE_SECRETS" | "$PORTHOLE_FLY_EXE" secrets import --stage -a "$1"),
          "sh",
          app
        ],
        env: [{"PORTHOLE_SECRETS", input}, {"PORTHOLE_FLY_EXE", executable()}],
        into: IO.stream()
      )

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
  def with_proxy(app, fun) do
    {:ok, socket} = :gen_tcp.listen(0, [])
    {:ok, port} = :inet.port(socket)
    :gen_tcp.close(socket)

    proxy =
      Port.open({:spawn_executable, executable()}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        args: ["proxy", "#{port}:4040", "-a", app]
      ])

    {:os_pid, os_pid} = Port.info(proxy, :os_pid)

    try do
      fun.(port)
    after
      System.cmd("kill", [to_string(os_pid)], stderr_to_stdout: true)
    end
  end

  @doc """
  Asks the sidecar which nodes it observes, retrying while it starts up and
  finds them. Returns the node names, or the last error.
  """
  @spec observed_nodes(pos_integer(), String.t(), non_neg_integer()) ::
          {:ok, [String.t()]} | {:error, String.t()}
  def observed_nodes(port, token, attempts \\ 30) do
    # Mix leaves OTP applications the project does not declare off the code path.
    Mix.ensure_application!(:inets)
    {:ok, _} = Application.ensure_all_started(:inets)

    body =
      JSON.encode!(%{
        jsonrpc: "2.0",
        id: 1,
        method: "tools/call",
        params: %{name: "query", arguments: %{sql: "SELECT node FROM system ORDER BY node"}}
      })

    request =
      {~c"http://localhost:#{port}/",
       [
         {~c"authorization", ~c"Bearer " ++ String.to_charlist(token)},
         {~c"accept", ~c"application/json, text/event-stream"}
       ], ~c"application/json", body}

    result =
      with {:ok, {{_, 200, _}, _headers, response}} <-
             :httpc.request(:post, request, [timeout: 15_000], body_format: :binary),
           %{"result" => %{"content" => [%{"text" => text}]}} <- JSON.decode!(response),
           %{"rows" => [_ | _] = rows} <- JSON.decode!(text) do
        {:ok, Enum.map(rows, &hd/1)}
      else
        {:ok, {{_, status, _}, _, _}} -> {:error, "the sidecar answered #{status}"}
        %{"rows" => []} = result -> {:error, describe_errors(result["errors"])}
        {:error, reason} -> {:error, "could not reach the sidecar: #{inspect(reason)}"}
        other -> {:error, "unexpected answer: #{inspect(other)}"}
      end

    case result do
      {:ok, nodes} ->
        {:ok, nodes}

      {:error, _} when attempts > 1 ->
        Process.sleep(2_000)
        observed_nodes(port, token, attempts - 1)

      error ->
        error
    end
  end

  defp describe_errors([_ | _] = errors),
    do: Enum.map_join(errors, "; ", &"#{&1["node"]}: #{&1["message"]}")

  defp describe_errors(_none), do: "no nodes found yet"

  defp json!(args, error) do
    case fly(args) do
      {output, 0} -> JSON.decode!(output)
      {_output, _status} -> Mix.raise(error)
    end
  end

  # stderr (warnings, errors) goes to the terminal, so stdout stays parseable.
  defp fly(args), do: System.cmd(executable(), args)
end
