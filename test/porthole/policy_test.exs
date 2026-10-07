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

  test "the environment policy can raise limits; tokens and requests only narrow them" do
    Application.put_env(:porthole, :policy, queries_per_minute: 1_000, max_rows: 200_000)
    on_exit(fn -> Application.delete_env(:porthole, :policy) end)

    env = Policy.environment()
    # A token with no policy of its own leaves the raised limits alone.
    assert %{queries_per_minute: 1_000, max_rows: 200_000} = Policy.intersect(env, Policy.new())

    # A token, or a request, narrows only what it sets.
    narrowed = Policy.intersect(env, Policy.new(max_rows: 10))
    assert %{max_rows: 10, queries_per_minute: 1_000} = narrowed

    # And never widens.
    assert %{max_rows: 200_000} = Policy.intersect(env, Policy.new(max_rows: 999_999_999))
  end
end
