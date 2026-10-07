defmodule Porthole.CLI do
  @moduledoc """
  Options shared by `mix porthole.query` and `mix porthole.mcp`:

    * `--connect NODE` / `--cookie COOKIE` - join a running node as a hidden
      node and query it, without starting this project's app. SQLite runs
      here; the target needs nothing from Porthole (Elixir on OTP 27+).
      Without `--cookie`, the cookie is read from `RELEASE_COOKIE`, which
      keeps it off the command line (where other users of the machine can
      see it, e.g. with `ps`).
    * `--node NODE` (repeatable) / `--all-nodes` - nodes to query.
    * `--window MS` - sampling window.
    * `--all-supervisors` - find supervisors by scanning every process (see
      `Porthole.Query.run/2`).
    * `--demo` - start the demo app (a small shop with planted problems) first
      (dev only, without `--connect`).
  """

  @switches [
    connect: :string,
    cookie: :string,
    node: :keep,
    all_nodes: :boolean,
    window: :integer,
    all_supervisors: :boolean,
    demo: :boolean
  ]

  @doc false
  # Returns the query options, the remaining arguments, and the parsed
  # options (including any task-specific `extra` switches).
  @spec setup!([String.t()], keyword()) :: {keyword(), [String.t()], keyword()}
  def setup!(args, extra \\ []) do
    # These commands run queries, which need SQLite (and the server, Plug and
    # Bandit): they run in a project that depends on Porthole. Installed as
    # an archive, Porthole carries no dependencies, only the trial commands.
    if Mix.Project.get() == nil do
      Mix.raise("""
      this command runs queries, so it needs a project that depends on Porthole and
      exqlite (e.g. your app, with {:porthole, ...} and {:exqlite, ...} as dev
      dependencies). Installed as an archive, Porthole provides the commands that
      need no project: mix porthole.fly.up / fly.down, porthole.k8s.up / k8s.down
      and porthole.gen.token.
      """)
    end

    {opts, rest} = OptionParser.parse!(args, strict: @switches ++ extra)

    target =
      if connect = opts[:connect] do
        Mix.Task.run("app.config")
        {:ok, _} = Application.ensure_all_started(:porthole)
        connect!(String.to_atom(connect), opts[:cookie])
      else
        Mix.Task.run("app.start")
        if opts[:demo], do: start_demo()
        nil
      end

    nodes =
      cond do
        opts[:all_nodes] && target -> [target | :erpc.call(target, Node, :list, [])]
        opts[:all_nodes] -> :all
        (nodes = Keyword.get_values(opts, :node)) != [] -> Enum.map(nodes, &String.to_atom/1)
        target -> [target]
        true -> nil
      end

    {[nodes: nodes, window_ms: opts[:window], all_supervisors: opts[:all_supervisors]], rest,
     opts}
  end

  defp connect!(target, cookie) do
    [_, host] = target |> Atom.to_string() |> String.split("@", parts: 2)
    domain = if host =~ ".", do: :longnames, else: :shortnames
    # net_kernel needs epmd, which `erl -sname` would have started.
    System.cmd("epmd", ["-daemon"])

    {:ok, _} =
      :net_kernel.start(:"porthole_#{System.pid()}", %{name_domain: domain, hidden: true})

    # From the environment unless given: a command-line argument is visible
    # to other users of the machine.
    cookie = cookie || System.get_env("RELEASE_COOKIE")
    if cookie, do: Node.set_cookie(String.to_atom(cookie))

    Node.connect(target) ||
      Mix.raise("""
      could not connect to #{target}. Usual causes:
        - the node is not running, or its name is different (check with `epmd -names` on its host)
        - the cookie differs (--cookie, or RELEASE_COOKIE, must match the node's cookie)
        - name types differ: a node started with --sname needs a short name here, --name a long one
        - epmd (port 4369) or the node's distribution port is not reachable from here
      """)

    target
  end

  defp start_demo do
    demo = Module.concat(Porthole, Demo)
    Code.ensure_loaded?(demo) || Mix.raise("--demo only works in dev and test")
    :ok = demo.start()
    Process.sleep(500)
  end
end
