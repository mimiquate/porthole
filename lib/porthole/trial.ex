defmodule Porthole.Trial do
  @moduledoc false
  # What `mix porthole.fly.*` and `mix porthole.k8s.*` share: reading a
  # running release's settings, checking what a freshly deployed sidecar
  # observes, and the safeguards around trial sidecars. The platform modules
  # (Porthole.Fly, Porthole.Kube) only drive their command-line tools.

  # Runs on an app machine or pod (fly ssh console, kubectl exec): prints the
  # settings of the running release from its own environment, so it works
  # whether the cookie is a fixed secret or was generated at build time.
  # Remote consoles and rpc calls (RELEASE_COMMAND=remote/rpc) are skipped.
  # With the argument `nocookie`, the cookie is left out (on Kubernetes, when
  # the sidecar can reference the app's own Secret instead).
  @inspect_script ~S"""
  keys='RELEASE_DISTRIBUTION|RELEASE_NODE|ERL_AFLAGS|DNS_CLUSTER_QUERY'
  [ "$1" = nocookie ] || keys="RELEASE_COOKIE|$keys"
  for p in /proc/[0-9]*; do
    case "$(tr '\0' ' ' < "$p/cmdline" 2>/dev/null)" in *beam.smp*) ;; *) continue ;; esac
    env="$(tr '\0' '\n' < "$p/environ" 2>/dev/null)" || continue
    case "$(printf '%s\n' "$env" | sed -n 's/^RELEASE_COMMAND=//p')" in start|start_iex|daemon|daemon_iex) ;; *) continue ;; esac
    printf '%s\n' "$env" | grep -E "^($keys)="
    exit 0
  done
  echo "no running Elixir release found here" >&2
  exit 3
  """

  @type release :: %{
          cookie: String.t() | nil,
          distribution: String.t() | nil,
          node: String.t() | nil,
          inet6: boolean(),
          dns: String.t() | nil
        }

  @doc """
  The sidecar image deployed by default, published from `main` by the
  repository's `sidecar-image` workflow (amd64 and arm64).
  """
  @spec default_image() :: String.t()
  def default_image, do: "ghcr.io/mimiquate/porthole-sidecar:latest"

  @doc "The environment variable that marks sidecars deployed by the `up` commands."
  @spec trial_marker() :: String.t()
  def trial_marker, do: "PORTHOLE_TRIAL"

  @doc """
  The inspection script as arguments for a tool that runs a program (e.g.
  `kubectl exec ... --`); `include_cookie: false` leaves the cookie out.
  """
  @spec inspect_argv(boolean()) :: [String.t()]
  def inspect_argv(include_cookie \\ true) do
    flag = if include_cookie, do: "", else: " nocookie"
    ["sh", "-c", "echo #{Base.encode64(@inspect_script)} | base64 -d | sh -s#{flag}"]
  end

  @doc "The same, as one command line, for tools that take one (`fly ssh console -C`)."
  @spec inspect_command(boolean()) :: String.t()
  def inspect_command(include_cookie \\ true) do
    ["sh", "-c", script] = inspect_argv(include_cookie)
    "sh -c '#{script}'"
  end

  @doc "Parses the inspection script's output (stdout only: it may hold the cookie)."
  @spec parse_release(String.t()) :: release()
  def parse_release(output) do
    vars =
      for line <- String.split(output, ["\r\n", "\n"]),
          [key, value] <- [String.split(line, "=", parts: 2)],
          into: %{},
          do: {key, value}

    %{
      cookie: vars["RELEASE_COOKIE"],
      distribution: vars["RELEASE_DISTRIBUTION"],
      node: vars["RELEASE_NODE"],
      inet6: String.contains?(vars["ERL_AFLAGS"] || "", "inet6_tcp"),
      dns: vars["DNS_CLUSTER_QUERY"]
    }
  end

  @doc """
  Runs `executable` with `args`, feeding `input` on stdin, so secrets never
  appear in a command line. Output is streamed to the terminal.
  """
  @spec run_with_input(String.t(), [String.t()], String.t()) :: non_neg_integer()
  def run_with_input(executable, args, input) do
    {_, status} =
      System.cmd(
        "sh",
        ["-c", ~S(printf '%s\n' "$PORTHOLE_INPUT" | "$@"), "sh", executable | args],
        env: [{"PORTHOLE_INPUT", input}],
        into: IO.stream(),
        stderr_to_stdout: true
      )

    status
  end

  @doc """
  Starts a tunnel (`executable` with the arguments `args.(local_port)`), runs
  `fun` with the local port, and closes the tunnel afterwards.
  """
  @spec with_tunnel(String.t(), (pos_integer() -> [String.t()]), (pos_integer() -> result)) ::
          result
        when result: term()
  def with_tunnel(executable, args, fun) do
    {:ok, socket} = :gen_tcp.listen(0, [])
    {:ok, port} = :inet.port(socket)
    :gen_tcp.close(socket)

    tunnel =
      Port.open({:spawn_executable, executable}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        args: args.(port)
      ])

    {:os_pid, os_pid} = Port.info(tunnel, :os_pid)

    try do
      fun.(port)
    after
      System.cmd("kill", [to_string(os_pid)], stderr_to_stdout: true)
    end
  end

  @doc """
  Asks the sidecar which nodes it observes, retrying while it starts up and
  finds them, until it sees `expected` nodes (the app's running instances)
  or gives up. Returns the node names (possibly fewer than expected), or the
  last error.
  """
  @spec observed_nodes(pos_integer(), String.t(), pos_integer(), non_neg_integer()) ::
          {:ok, [String.t()]} | {:error, String.t()}
  def observed_nodes(port, token, expected, attempts \\ 30) do
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
           {:ok, %{"result" => result}} <- JSON.decode(response),
           {:ok, text} <- tool_text(result),
           {:ok, %{"rows" => [_ | _] = rows}} <- JSON.decode(text) do
        {:ok, Enum.map(rows, &hd/1)}
      else
        {:ok, {{_, status, _}, _, _}} -> {:error, "the sidecar answered #{status}"}
        {:tool_error, text} -> {:error, String.trim(text)}
        {:ok, %{"rows" => []} = result} -> {:error, describe_errors(result["errors"])}
        {:error, reason} -> {:error, "could not reach the sidecar: #{inspect(reason)}"}
        other -> {:error, "unexpected answer: #{inspect(other)}"}
      end

    case result do
      {:ok, nodes} when length(nodes) >= expected or attempts <= 1 ->
        {:ok, nodes}

      _not_yet when attempts > 1 ->
        Process.sleep(2_000)
        observed_nodes(port, token, expected, attempts - 1)

      error ->
        error
    end
  end

  @doc """
  What `up` says about what the sidecar observes, given how many instances
  the app runs.
  """
  @spec report({:ok, [String.t()]} | {:error, String.t()}, String.t(), String.t(), pos_integer()) ::
          {:ok | :error, String.t()}
  def report({:ok, nodes}, sidecar, app, expected) when length(nodes) >= expected,
    do: {:ok, "#{sidecar} observes #{length(nodes)} node(s) of #{app}: #{Enum.join(nodes, ", ")}"}

  def report({:ok, nodes}, sidecar, app, expected),
    do:
      {:error,
       "#{sidecar} observes only #{length(nodes)} of #{app}'s #{expected} instances: " <>
         "#{Enum.join(nodes, ", ")}. The others may be restarting, or unreachable from the sidecar"}

  def report({:error, reason}, sidecar, _app, _expected),
    do: {:error, "#{sidecar} is running but observes no nodes yet: #{reason}"}

  @doc "Asks for `name` to be typed before destroying it; anything else cancels."
  @spec confirmed?(String.t()) :: boolean()
  def confirmed?(name) do
    answer = Mix.shell().prompt("Type #{name} to destroy it (anything else cancels):")

    if String.trim(answer) == name do
      true
    else
      Mix.shell().info("Cancelled: nothing was destroyed.")
      false
    end
  end

  # A tool error (e.g. no nodes to query yet) is plain text, not rows.
  defp tool_text(%{"isError" => true, "content" => [%{"text" => text}]}),
    do: {:tool_error, text}

  defp tool_text(%{"content" => [%{"text" => text}]}), do: {:ok, text}
  defp tool_text(other), do: other

  defp describe_errors([_ | _] = errors),
    do: Enum.map_join(errors, "; ", &"#{&1["node"]}: #{&1["message"]}")

  defp describe_errors(_none), do: "no nodes found yet"
end
