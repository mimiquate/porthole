defmodule Porthole.LimitsTest do
  # Synchronous modules run after all async ones, so these tests have the
  # limiter to themselves.
  use ExUnit.Case, async: false

  alias Porthole.{Error, Policy}

  defp client, do: "client-#{System.unique_integer([:positive])}"

  describe "queries per minute" do
    test "applies per identified client" do
      policy = Policy.new(queries_per_minute: 2)
      [a, b] = [client(), client()]

      assert {:ok, _} = Porthole.query("SELECT 1", client: a, policy: policy)
      assert {:ok, _} = Porthole.query("SELECT 1", client: a, policy: policy)

      assert {:error, %Error{reason: :rate_limited, message: message}} =
               Porthole.query("SELECT 1", client: a, policy: policy)

      assert message =~ "2 queries per minute"
      assert message =~ ~r/retry in \d+s/

      assert {:ok, _} = Porthole.query("SELECT 1", client: b, policy: policy)
    end

    test "rejected queries do not count" do
      policy = Policy.new(queries_per_minute: 1)
      a = client()

      assert {:ok, _} = Porthole.query("SELECT 1", client: a, policy: policy)

      for _ <- 1..3 do
        assert {:error, %Error{reason: :rate_limited}} =
                 Porthole.query("SELECT 1", client: a, policy: policy)
      end

      # Four attempts, one admitted: the limiter only remembers that one.
      assert %{recent: %{^a => [_]}} = :sys.get_state(Porthole.Limiter)
    end

    test "direct library calls, without a client, are not rate limited" do
      policy = Policy.new(queries_per_minute: 1)

      for _ <- 1..3, do: assert({:ok, _} = Porthole.query("SELECT 1", policy: policy))
    end
  end

  describe "concurrency" do
    test "limits queries running at the same time" do
      policy = Policy.new(max_concurrent: 1)

      slow =
        Task.async(fn ->
          Porthole.query("SELECT max(reductions_delta) FROM processes",
            policy: policy,
            window_ms: 300
          )
        end)

      Process.sleep(50)

      assert {:error, %Error{reason: :busy, message: message}} =
               Porthole.query("SELECT 1", policy: policy)

      assert message =~ "1 queries are already running"

      assert {:ok, _} = Task.await(slow)
      assert {:ok, _} = Porthole.query("SELECT 1", policy: policy)
    end

    test "a query that dies releases its slot" do
      policy = Policy.new(max_concurrent: 1)

      doomed =
        spawn(fn ->
          Porthole.query("SELECT max(reductions_delta) FROM processes",
            policy: policy,
            window_ms: 5_000
          )
        end)

      Process.sleep(50)
      assert {:error, %Error{reason: :busy}} = Porthole.query("SELECT 1", policy: policy)

      Process.exit(doomed, :kill)
      Process.sleep(50)
      assert {:ok, _} = Porthole.query("SELECT 1", policy: policy)
    end
  end

  describe "bytes loaded (max_bytes)" do
    test "bound what one query loads, and say so" do
      total = Porthole.query!("SELECT count(*) FROM processes").rows |> hd() |> hd()

      result =
        Porthole.query!("SELECT count(*) FROM processes", policy: Policy.new(max_bytes: 5_000))

      assert [[capped]] = result.rows
      assert capped < total
      assert result.truncated
      assert [note] = result.notes

      assert note =~
               "processes on #{node()}: only #{capped} rows were loaded, this node's share " <>
                 "of the query's 5000-byte budget (max_bytes)"
    end

    test "are split evenly between the tables (and nodes) of a query" do
      sql = "SELECT (SELECT count(*) FROM processes), (SELECT count(*) FROM ets_tables)"
      [[processes, ets]] = Porthole.query!(sql, policy: Policy.new(max_bytes: 10_000)).rows

      [[alone]] =
        Porthole.query!("SELECT count(*) FROM processes", policy: Policy.new(max_bytes: 5_000)).rows

      # Each table got half of the budget (give or take processes that came
      # and went between the two queries).
      assert abs(processes - alone) <= 3
      assert ets > 0
    end
  end
end
