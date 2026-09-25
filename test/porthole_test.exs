defmodule PortholeTest do
  use ExUnit.Case, async: true
  doctest Porthole

  alias Porthole.Term

  test "schema/0 lists every table with its sampled columns" do
    assert Enum.map(Porthole.schema(), & &1.name) ==
             ~w(processes supervisors ets_tables ports applications system)

    assert [%{name: "processes", sampled: sampled} | _] = Porthole.schema()
    assert :reductions_delta in sampled
  end

  test "collect/2 returns plain rows and flags truncation" do
    {:ok, {rows, false}} = Porthole.collect("processes")
    assert Enum.any?(rows, &(&1.registered_name == "application_controller"))
    assert {:ok, {[_, _], true}} = Porthole.collect("processes", 2)
    assert :error = Porthole.collect("sockets")
  end

  describe "Term" do
    doctest Porthole.Term

    test "large terms become bounded shapes" do
      rendered = Term.render(Map.new(1..100_000, &{&1, String.duplicate("x", 100)}))
      assert byte_size(rendered) <= 256
      assert %{"type" => "map", "size" => 100_000} = JSON.decode!(rendered)

      assert %{"length" => "10000+"} =
               JSON.decode!(Term.render(List.duplicate(String.duplicate("x", 100), 20_000)))
    end

    test "custom Inspect implementations are respected" do
      rendered = Term.render(%Porthole.Test.Secret{user: "ana", token: "s3cr3t"})
      assert rendered =~ "ana"
      refute rendered =~ "s3cr3t"
    end

    test "truncate/2 never splits a codepoint" do
      assert Term.truncate(String.duplicate("é", 100), 10) |> String.valid?()
    end
  end
end
