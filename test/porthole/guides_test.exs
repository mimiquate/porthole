defmodule Porthole.GuidesTest do
  @moduledoc """
  Runs every SQL block in guides/ against the demo tree, so documented
  queries stay valid as the schema evolves. A block's `-- window_ms: N`
  comment makes it run with a (shortened) sampling window, and
  `-- trace: kind=target` with that trace.
  """
  use ExUnit.Case, async: false

  setup_all do
    Porthole.Demo.start()
    on_exit(&Porthole.Demo.stop/0)
    Application.put_env(:porthole, :policy, tiers: [:observe, :trace], trace_shapes: true)
    on_exit(fn -> Application.delete_env(:porthole, :policy) end)
    Process.sleep(100)
    :ok
  end

  for path <- Path.wildcard("guides/*.md"),
      {sql, index} <-
        Regex.scan(~r/```sql\n(.*?)```/s, File.read!(path), capture: :all_but_first)
        |> Enum.with_index() do
    @external_resource path
    @sql hd(sql)

    test "#{Path.basename(path)} query ##{index + 1}" do
      window = if Regex.match?(~r/-- window_ms: \d+/, @sql), do: 50

      trace =
        case Regex.run(~r/-- trace: (\w+)=(\S+)/, @sql) do
          [_, kind, target] -> %{kind => target}
          nil -> nil
        end

      opts = [window_ms: if(trace, do: 300, else: window), trace: trace]

      assert {:ok, %Porthole.Result{} = result} = Porthole.query(@sql, opts),
             "query failed:\n#{@sql}\n#{inspect(Porthole.query(@sql, opts))}"

      # A trace example must find something in the demo.
      if trace, do: assert(result.rows != [], "no rows:\n#{@sql}")
    end
  end
end
