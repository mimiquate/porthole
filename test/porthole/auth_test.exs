defmodule Porthole.AuthTest do
  use ExUnit.Case, async: true

  alias Porthole.Auth

  test "tokens are random and prefixed" do
    assert "ph_" <> _ = token = Auth.generate()
    refute token == Auth.generate()
  end

  test "verify/2 finds the client by token" do
    token = Auth.generate()

    clients =
      Auth.load!([
        [id: "a", sha256: Auth.hash(Auth.generate())],
        [id: "b", sha256: Auth.hash(token)]
      ])

    assert {:ok, %{id: "b"}} = Auth.verify(clients, token)
    assert :error = Auth.verify(clients, Auth.generate())
  end

  test "policies are built from config" do
    [client] = Auth.load!([%{id: :ci, sha256: Auth.hash("x"), policy: [max_result_rows: 5]}])
    assert %{id: "ci", policy: %Porthole.Policy{max_result_rows: 5}} = client
  end

  test "misconfiguration fails loudly" do
    assert_raise ArgumentError, ~r/must be a list of entries/, fn ->
      Auth.load!(id: "a", sha256: Auth.hash("x"))
    end

    assert_raise ArgumentError, ~r/must be a list of entries/, fn -> Auth.load!(%{id: "a"}) end
    assert_raise ArgumentError, ~r/needs an :id/, fn -> Auth.load!([[sha256: Auth.hash("x")]]) end
    assert_raise ArgumentError, ~r/needs :sha256/, fn -> Auth.load!([[id: "a"]]) end

    assert_raise ArgumentError, ~r/needs :sha256/, fn ->
      Auth.load!([[id: "a", sha256: "not-hex"]])
    end

    assert_raise ArgumentError, ~r/unique/, fn ->
      Auth.load!([[id: "a", sha256: Auth.hash("x")], [id: "a", sha256: Auth.hash("y")]])
    end

    assert_raise KeyError, fn ->
      Auth.load!([[id: "a", sha256: Auth.hash("x"), policy: [bogus: 1]]])
    end
  end
end
