defmodule Porthole.CLI do
  @moduledoc """
  Options shared by `mix porthole.query` and `mix porthole.mcp`:

    * `--connect NODE` / `--cookie COOKIE` - join a running node as a hidden
      node and query it, without starting this project's app. SQLite runs
      here; the target only needs Porthole's collector.
    * `--node NODE` (repeatable) / `--all-nodes` - nodes to query.
    * `--window MS` - sampling window.
    * `--demo` - start `Porthole.Demo`, an app with planted problems, first
      (dev only, without `--connect`).
  """

  @switches [
    connect: :string,
    cookie: :string,
    node: :keep,
    all_nodes: :boolean,
    window: :integer,
    demo: :boolean
  ]

  @doc false
  # Returns the query options, the remaining arguments, and the parsed
  # options (including any task-specific `extra` switches).
  @spec setup!([String.t()], keyword()) :: {keyword(), [String.t()], keyword()}
  def setup!(args, extra \\ []) do
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

    {[nodes: nodes, window_ms: opts[:window]], rest, opts}
  end

  defp connect!(target, cookie) do
    [_, host] = target |> Atom.to_string() |> String.split("@", parts: 2)
    domain = if host =~ ".", do: :longnames, else: :shortnames
    # net_kernel needs epmd, which `erl -sname` would have started.
    System.cmd("epmd", ["-daemon"])

    {:ok, _} =
      :net_kernel.start(:"porthole_#{System.pid()}", %{name_domain: domain, hidden: true})

    if cookie, do: Node.set_cookie(String.to_atom(cookie))
    Node.connect(target) || Mix.raise("could not connect to #{target}")
    target
  end

  defp start_demo do
    demo = Module.concat(Porthole, Demo)
    Code.ensure_loaded?(demo) || Mix.raise("--demo only works in dev and test")
    :ok = demo.start()
    Process.sleep(500)
  end
end
