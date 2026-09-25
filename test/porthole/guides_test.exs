defmodule Porthole.GuidesTest do
  @moduledoc """
  Runs every SQL block in guides/ against the demo tree, so documented
  queries stay valid as the schema evolves. A block's `-- window_ms: N`
  comment makes it run with a (shortened) sampling window.
  """
  use ExUnit.Case, async: false

  setup_all do
    start_supervised!(Porthole.Demo)
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

      assert {:ok, %Porthole.Result{}} = Porthole.query(@sql, window_ms: window),
             "query failed:\n#{@sql}\n#{inspect(Porthole.query(@sql, window_ms: window))}"
    end
  end
end
