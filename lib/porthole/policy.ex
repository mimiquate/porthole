defmodule Porthole.Policy do
  @moduledoc """
  What an agent may see, and how much it may ask for.

  Every capability tier is defined; `:observe` and `:trace` are implemented:

  | Tier        | Examples                                  |
  |-------------|-------------------------------------------|
  | `:observe`  | table queries, sampled stats              |
  | `:trace`    | budgeted trace sessions (`Porthole.Trace`) |
  | `:evaluate` | code eval, `:sys.get_state`               |
  | `:mutate`   | kill, `:sys.replace_state`, hot code load |

  Policies compose by **intersection**, so the effective policy of a request
  is `environment ∩ session ∩ request`: tiers and nodes are intersected,
  limits take the minimum. The environment policy comes from
  `config :porthole, :policy, [...]`.

  The environment allows only `:observe` by default: enable tracing with
  `config :porthole, :policy, tiers: [:observe, :trace]`.
  """

  alias Porthole.Error

  @tiers [:observe, :trace, :evaluate, :mutate]

  @type tier :: :observe | :trace | :evaluate | :mutate

  @typedoc """
  * `:tiers` - enabled tiers.
  * `:nodes` - nodes that may be queried, or `:all`.
  * `:max_rows` - rows collected per table, per node (enforced on the node).
  * `:max_bytes` - bytes loaded into the query engine per query, across all
    nodes and tables: the querying node's memory budget for one query. Each
    node and table gets an equal share; rows beyond a share are not loaded,
    and the result says so.
  * `:max_result_rows` - rows returned.
  * `:max_window_ms` - longest sampling window.
  * `:timeout_ms` - budget for collecting and for running the SQL.
  * `:queries_per_minute` - queries a client may run per minute (applies to
    identified clients, such as agents connected through MCP).
  * `:max_concurrent` - queries that may run at the same time on the
    querying node, across all clients.
  * `:max_trace_events` - events a trace may produce on each node before it
    is stopped (counted as the VM produces them). Events wait in the tracing
    process until read, under a memory cap: raised far above the default (to
    ~100k and more), a flood can fill that cap and the trace returns nothing.
  * `:trace_shapes` - whether traces may record the shapes of a function's
    arguments and results (`Porthole.Trace`, `shapes`). Shapes show map keys
    as they are, and keys can be data (emails, ids): set it to `false` to
    trace without them. Any layer can turn it off; none can turn it back on.
  * `:max_trace_window_ms` - longest window for a trace. Lower than
    `:max_window_ms`: a sampling window costs nothing while it waits, a trace
    costs for as long as it runs.

  Limits are `:infinity` in a policy that does not set them (see `new/1`);
  every query intersects with the environment policy, which sets them all.
  """
  @type limit :: pos_integer() | :infinity
  @type t :: %__MODULE__{
          tiers: [tier()],
          nodes: :all | [node()],
          max_rows: limit(),
          max_bytes: limit(),
          max_result_rows: limit(),
          max_window_ms: limit(),
          timeout_ms: limit(),
          queries_per_minute: limit(),
          max_concurrent: limit(),
          max_trace_events: limit(),
          max_trace_window_ms: limit(),
          trace_shapes: boolean()
        }

  defstruct tiers: [:observe],
            nodes: :all,
            max_rows: 50_000,
            max_bytes: 50_000_000,
            max_result_rows: 500,
            max_window_ms: 60_000,
            timeout_ms: 10_000,
            queries_per_minute: 60,
            max_concurrent: 4,
            max_trace_events: 10_000,
            max_trace_window_ms: 10_000,
            trace_shapes: true

  @limits [
    :max_rows,
    :max_bytes,
    :max_result_rows,
    :max_window_ms,
    :timeout_ms,
    :queries_per_minute,
    :max_concurrent,
    :max_trace_events,
    :max_trace_window_ms
  ]

  @doc "All tiers, least to most powerful."
  @spec tiers() :: [tier()]
  def tiers, do: @tiers

  @doc """
  Builds a policy that constrains only what `opts` sets: every tier, every
  node and no limit otherwise. Used for the session (a token's policy) and
  request layers, which can only narrow the environment policy: a limit they
  leave unset is the environment's, whatever it is configured to.
  """
  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    unlimited = for key <- @limits, do: {key, :infinity}
    struct!(%__MODULE__{tiers: @tiers}, unlimited ++ opts)
  end

  @doc """
  The environment policy, from `config :porthole, :policy`: the defaults
  below, overridden by the configuration, raised or lowered.
  """
  @spec environment() :: t()
  def environment, do: struct!(__MODULE__, Application.get_env(:porthole, :policy, []))

  @doc """
  Intersects two policies.

      iex> a = Porthole.Policy.new(tiers: [:observe, :trace], max_result_rows: 10)
      iex> b = Porthole.Policy.new(tiers: [:observe], nodes: [:a@host])
      iex> Porthole.Policy.intersect(a, b) |> Map.take([:tiers, :nodes, :max_result_rows])
      %{tiers: [:observe], nodes: [:a@host], max_result_rows: 10}

  """
  @spec intersect(t(), t()) :: t()
  def intersect(a, b) do
    limits = for key <- @limits, do: {key, min(Map.fetch!(a, key), Map.fetch!(b, key))}

    struct!(
      %__MODULE__{
        tiers: Enum.filter(a.tiers, &(&1 in b.tiers)),
        trace_shapes: a.trace_shapes and b.trace_shapes,
        nodes:
          case {a.nodes, b.nodes} do
            {:all, nodes} -> nodes
            {nodes, :all} -> nodes
            {x, y} -> Enum.filter(x, &(&1 in y))
          end
      },
      limits
    )
  end

  @doc """
  Lets queries trace: adds `:trace` to the environment policy's tiers (for
  servers configured by flags or environment variables rather than
  `config :porthole, :policy`).
  """
  @spec allow_tracing() :: :ok
  def allow_tracing do
    policy = Application.get_env(:porthole, :policy, [])
    tiers = Keyword.get(policy, :tiers, [:observe])

    Application.put_env(
      :porthole,
      :policy,
      Keyword.put(policy, :tiers, Enum.uniq(tiers ++ [:trace]))
    )
  end

  @doc """
  Disallows shapes in traces (`trace_shapes: false` in the environment
  policy), for servers configured by flags or environment variables.
  """
  @spec forbid_trace_shapes() :: :ok
  def forbid_trace_shapes do
    policy = Application.get_env(:porthole, :policy, [])
    Application.put_env(:porthole, :policy, Keyword.put(policy, :trace_shapes, false))
  end

  @doc "Checks that the policy allows `tier` and that it is implemented."
  @spec authorize(t(), tier()) :: :ok | {:error, Error.t()}
  def authorize(%__MODULE__{tiers: tiers}, tier) do
    cond do
      tier not in tiers ->
        {:error,
         Error.new(
           :not_allowed,
           "the #{tier} tier is not allowed by the policy" <>
             if(tier == :trace, do: " (tracing is off unless the server enables it)", else: "")
         )}

      tier not in [:observe, :trace] ->
        {:error,
         Error.new(
           :not_enabled,
           "the #{tier} tier is not enabled; only observe and trace are available"
         )}

      true ->
        :ok
    end
  end

  @doc "Checks that the policy allows querying every node in `nodes`."
  @spec authorize_nodes(t(), [node()]) :: :ok | {:error, Error.t()}
  def authorize_nodes(%__MODULE__{nodes: :all}, _nodes), do: :ok

  def authorize_nodes(%__MODULE__{nodes: allowed}, nodes) do
    case nodes -- allowed do
      [] ->
        :ok

      denied ->
        {:error,
         Error.new(
           :not_allowed,
           "querying #{Enum.join(denied, ", ")} is not allowed by the policy"
         )}
    end
  end
end
