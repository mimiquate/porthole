defmodule Porthole.PolicyTest do
  use ExUnit.Case, async: true
  doctest Porthole.Policy

  alias Porthole.{Error, Policy}

  test "every tier is defined, only observe is implemented" do
    policy = Policy.new()
    assert Policy.tiers() == [:observe, :trace, :evaluate, :mutate]
    assert :ok = Policy.authorize(policy, :observe)

    for tier <- [:trace, :evaluate, :mutate] do
      assert {:error, %Error{reason: :not_enabled}} = Policy.authorize(policy, tier)
    end
  end

  test "tiers missing from the policy are not allowed" do
    assert {:error, %Error{reason: :not_allowed}} =
             Policy.authorize(Policy.new(tiers: []), :observe)
  end

  test "the environment policy only enables observe" do
    assert Policy.environment().tiers == [:observe]
  end

  test "intersection only narrows" do
    a = Policy.new(nodes: [:a@h, :b@h], max_result_rows: 10, timeout_ms: 5_000)
    b = Policy.new(tiers: [:observe], nodes: [:b@h, :c@h], max_result_rows: 100)

    assert %{tiers: [:observe], nodes: [:b@h], max_result_rows: 10, timeout_ms: 5_000} =
             Policy.intersect(a, b)
  end

  test "nodes" do
    assert :ok = Policy.authorize_nodes(Policy.new(), [:x@h])

    assert {:error, %Error{reason: :not_allowed}} =
             Policy.authorize_nodes(Policy.new(nodes: [:a@h]), [:a@h, :b@h])
  end
end
