defmodule Porthole.Limiter do
  @moduledoc """
  Admission control for queries on the querying node.

  Three limits, all from the effective `Porthole.Policy`:

    * `:max_concurrent` - queries running at the same time, across all
      clients. Each query walks every process on the observed nodes, so
      piling them up is what hurts a node under stress.
    * `:queries_per_minute` - per client, over a sliding minute. Applied to
      identified clients (agents connected through MCP); direct library calls
      carry no client and are only subject to the concurrency limit.
    * `:max_concurrent_traces` - queries with a trace running at the same
      time (`Porthole.Trace`). Each trace has its own limits on the nodes
      (events, memory, setup): one at a time keeps their sum at one trace's.

  The limiter monitors each running query's process, so a query that crashes
  or is killed releases its slot. Rejected queries do not count toward the
  rate. Rejections are ordinary errors (`:busy`, `:rate_limited`) that tell
  the agent when to retry.
  """

  use GenServer

  alias Porthole.{Error, Policy}

  @window_ms 60_000

  @doc false
  def start_link(_opts), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @doc """
  Admits the calling process's query, or explains why not. On success,
  returns a ticket to pass to `release/1` when the query is done.
  """
  @spec acquire(String.t() | nil, Policy.t(), boolean()) ::
          {:ok, reference()} | {:error, Error.t()}
  def acquire(client, %Policy{} = policy, trace? \\ false) do
    GenServer.call(
      __MODULE__,
      {:acquire, client, policy.queries_per_minute, policy.max_concurrent,
       if(trace?, do: policy.max_concurrent_traces)}
    )
  end

  @doc "Releases a slot taken by `acquire/3`."
  @spec release(reference()) :: :ok
  def release(ticket), do: GenServer.cast(__MODULE__, {:release, ticket})

  @impl true
  def init(nil), do: {:ok, %{running: %{}, recent: %{}}}

  @impl true
  def handle_call({:acquire, client, per_minute, max_concurrent, max_traces}, {pid, _tag}, state) do
    now = System.monotonic_time(:millisecond)
    recent = recent(state, client, now)

    cond do
      client != nil and length(recent) >= per_minute ->
        retry_s = div(List.last(recent) + @window_ms - now, 1_000) + 1

        {:reply,
         {:error,
          Error.new(
            :rate_limited,
            "rate limit reached: #{per_minute} queries per minute for this client; retry in #{retry_s}s"
          )}, put_recent(state, client, recent)}

      map_size(state.running) >= max_concurrent ->
        {:reply,
         {:error,
          Error.new(
            :busy,
            "#{max_concurrent} queries are already running on this node; retry in a few seconds"
          )}, put_recent(state, client, recent)}

      max_traces != nil and traces(state) >= max_traces ->
        {:reply,
         {:error,
          Error.new(
            :busy,
            "a trace is already running (#{max_traces} at a time); retry when it ends, " <>
              "in a few seconds, or query without a trace"
          )}, put_recent(state, client, recent)}

      true ->
        ticket = Process.monitor(pid)
        state = put_recent(state, client, if(client, do: [now | recent], else: recent))
        {:reply, {:ok, ticket}, put_in(state.running[ticket], {pid, max_traces != nil})}
    end
  end

  @impl true
  def handle_cast({:release, ticket}, state) do
    Process.demonitor(ticket, [:flush])
    {:noreply, %{state | running: Map.delete(state.running, ticket)}}
  end

  @impl true
  def handle_info({:DOWN, ticket, :process, _pid, _reason}, state) do
    {:noreply, %{state | running: Map.delete(state.running, ticket)}}
  end

  defp traces(state), do: Enum.count(state.running, fn {_ticket, {_pid, trace?}} -> trace? end)

  # Admission times within the last minute, newest first.
  defp recent(_state, nil, _now), do: []

  defp recent(state, client, now) do
    state.recent |> Map.get(client, []) |> Enum.take_while(&(&1 > now - @window_ms))
  end

  defp put_recent(state, nil, _recent), do: state
  defp put_recent(state, client, []), do: %{state | recent: Map.delete(state.recent, client)}
  defp put_recent(state, client, recent), do: put_in(state.recent[client], recent)
end
