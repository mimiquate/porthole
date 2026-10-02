defmodule Porthole.Query do
  @moduledoc """
  Runs SQL over a throwaway, in-memory SQLite database.

  SQLite is not a replica of the node. For every query Porthole:

    1. finds which tables the SQL mentions,
    2. collects those tables right now, on every requested node,
    3. loads the rows into a new in-memory database (with a `node` column),
    4. runs the query with a time budget and a row cap, and
    5. discards the database.

  SQLite brings the query language: joins, `GROUP BY`, aggregates, subqueries
  and `ORDER BY ... LIMIT`, so agents compose questions instead of calling
  one narrow tool per question.

  Read-only access is enforced by a SQLite authorizer, installed after the
  data is loaded, that denies every write, `ATTACH`, `PRAGMA` and schema
  change.

  Every query emits `[:porthole, :query, :start | :stop | :exception]`
  telemetry events with the SQL and outcome, for audit logging.
  """

  # exqlite is optional: only the querying node needs it.
  @compile {:no_warn_undefined, Exqlite.Sqlite3}

  alias Exqlite.Sqlite3
  alias Porthole.{Collector, Error, Limiter, Policy, Result, Table, Term}

  @deny ~w(attach detach pragma insert update delete create_table drop_table create_index
           drop_index create_trigger drop_trigger create_view drop_view alter_table reindex
           analyze savepoint transaction create_temp_table create_temp_index create_temp_trigger
           create_temp_view drop_temp_table drop_temp_index drop_temp_trigger drop_temp_view
           create_vtable drop_vtable)a

  @max_cell_bytes 1_024

  @doc """
  Runs `sql`. Options:

    * `:window_ms` - sample over a window, adding `_delta` columns.
    * `:nodes` - `nil` (this node), `:all` (this node and every connected
      one), a list of node names, or a zero-arity function returning one of
      those, called for every query (e.g. a sidecar's current cluster).
    * `:policy` - the session `Porthole.Policy`.
    * `:client` - who is asking (e.g. a token id). Identified clients are
      subject to the policy's `:queries_per_minute`; every query is subject
      to `:max_concurrent`. See `Porthole.Limiter`.
    * `:max_result_rows`, `:max_rows`, `:timeout_ms` - narrow the policy for
      this request.
    * `:all_supervisors` - find supervisors by scanning every process,
      instead of walking the applications' supervision trees. Also finds
      supervisors outside those trees, at a cost proportional to the number
      of processes. Default `false`.
  """
  @spec run(String.t(), keyword()) :: {:ok, Result.t()} | {:error, Error.t()}
  def run(sql, opts \\ []) do
    :telemetry.span([:porthole, :query], %{sql: sql}, fn ->
      result = do_run(sql, opts)
      {result, %{sql: sql, result: result}}
    end)
  end

  @doc "Whether this node can run queries (i.e. the SQLite NIF is available)."
  @spec available?() :: boolean()
  def available?, do: Code.ensure_loaded?(Sqlite3)

  defp do_run(sql, opts) do
    policy =
      Policy.environment()
      |> Policy.intersect(opts[:policy] || Policy.new())
      |> Policy.intersect(
        Policy.new(Keyword.take(opts, [:max_rows, :max_result_rows, :timeout_ms]))
      )

    window = opts[:window_ms]

    with :ok <- Policy.authorize(policy, :observe),
         :ok <- check_window(window, policy),
         {:ok, nodes} <- nodes(opts[:nodes]),
         :ok <- Policy.authorize_nodes(policy, nodes),
         {:ok, ticket} <- Limiter.acquire(opts[:client], policy) do
      try do
        run_admitted(sql, nodes, window, policy, opts[:all_supervisors] == true)
      after
        Limiter.release(ticket)
      end
    end
  end

  defp run_admitted(sql, nodes, window, policy, all_supervisors) do
    tables = for table <- Table.all(), sql =~ ~r/\b#{table.name()}\b/i, do: table
    names = Enum.map(tables, & &1.name())

    limits = %{
      max_rows: policy.max_rows,
      max_bytes: policy.max_bytes,
      all_supervisors: all_supervisors
    }

    {collected, errors} = Collector.collect(nodes, names, window, limits, policy.timeout_ms)

    with {:ok, columns, rows, more?} <- execute(sql, tables, collected, window, policy) do
      {rows, shortened} = shorten_cells(rows)

      notes =
        List.flatten([
          if(more?, do: "only the first #{policy.max_result_rows} rows are returned", else: []),
          if(shortened > 0,
            do: "#{shortened} cells were cut to #{@max_cell_bytes} bytes",
            else: []
          ),
          for {node, tables} <- collected, {name, {_, cut}} <- tables, cut do
            limit =
              if cut == :bytes, do: "#{policy.max_bytes} bytes", else: "#{policy.max_rows} rows"

            "#{name} on #{node}: collection stopped at #{limit}, aggregates are incomplete"
          end
        ])

      {:ok,
       %Result{
         columns: columns,
         rows: rows,
         truncated: notes != [],
         notes: notes,
         errors: for({node, message} <- errors, do: %{node: to_string(node), message: message}),
         nodes: Enum.map(nodes, &to_string/1),
         window_ms: window
       }}
    end
  end

  defp check_window(nil, _policy), do: :ok

  defp check_window(window, policy)
       when is_integer(window) and window > 0 and window <= policy.max_window_ms,
       do: :ok

  defp check_window(window, policy),
    do:
      {:error,
       Error.new(
         :bad_request,
         "window_ms must be between 1 and #{policy.max_window_ms}, got #{inspect(window)}"
       )}

  defp nodes(nil), do: {:ok, [node()]}
  defp nodes(:all), do: {:ok, [node() | Node.list()]}
  defp nodes(fun) when is_function(fun, 0), do: nodes(fun.())

  defp nodes([]),
    do:
      {:error,
       Error.new(:bad_request, "there are no nodes to query (none connected or none requested)")}

  defp nodes(names) when is_list(names) do
    # Never create atoms from request input: unknown nodes have no atom yet.
    {:ok, Enum.map(names, &if(is_atom(&1), do: &1, else: String.to_existing_atom(&1)))}
  rescue
    ArgumentError -> {:error, Error.new(:bad_request, "unknown node in #{inspect(names)}")}
  end

  defp execute(sql, tables, collected, window, policy) do
    {:ok, conn} = Sqlite3.open(":memory:")

    try do
      :ok = Sqlite3.execute(conn, "BEGIN")
      Enum.each(tables, &load(conn, &1, collected, window != nil))
      :ok = Sqlite3.execute(conn, "COMMIT")
      :ok = Sqlite3.set_authorizer(conn, @deny)

      case Sqlite3.prepare(conn, sql) do
        {:ok, statement} -> fetch(conn, statement, policy)
        {:error, message} -> {:error, sql_error(message, window)}
      end
    after
      Sqlite3.close(conn)
    end
  end

  defp load(conn, table, collected, sampled?) do
    columns = [{:node, :text, ""} | Table.columns(table, sampled?)]

    definitions =
      Enum.map_join(columns, ", ", fn {name, type, _doc} -> ~s("#{name}" #{sql_type(type)}) end)

    placeholders = Enum.map_join(columns, ", ", fn _ -> "?" end)

    :ok = Sqlite3.execute(conn, ~s[CREATE TABLE "#{table.name()}" (#{definitions})])

    {:ok, insert} =
      Sqlite3.prepare(conn, ~s[INSERT INTO "#{table.name()}" VALUES (#{placeholders})])

    for {node, tables} <- collected, row <- elem(tables[table.name()], 0) do
      row = Map.put(row, :node, Atom.to_string(node))
      :ok = Sqlite3.bind(insert, Enum.map(columns, fn {name, _, _} -> sql_value(row[name]) end))
      :done = Sqlite3.step(conn, insert)
    end

    Sqlite3.release(conn, insert)
  end

  defp fetch(conn, statement, policy) do
    # Cancel the query if it runs past its budget (e.g. an accidental
    # cartesian product or an unbounded recursive CTE).
    {:ok, timer} = :timer.apply_after(policy.timeout_ms, Sqlite3, :cancel, [conn])
    {:ok, columns} = Sqlite3.columns(conn, statement)
    fetched = fetch_rows(conn, statement, policy.max_result_rows + 1, [])
    :timer.cancel(timer)

    case fetched do
      {:ok, rows} ->
        {rows, rest} = Enum.split(rows, policy.max_result_rows)
        {:ok, columns, rows, rest != []}

      {:error, message} ->
        if message =~ "interrupt",
          do:
            {:error,
             Error.new(
               :timeout,
               "the query ran longer than #{policy.timeout_ms}ms and was cancelled"
             )},
          else: {:error, Error.new(:sql_error, message)}
    end
  end

  # Stops stepping once `limit` rows are in.
  defp fetch_rows(conn, statement, limit, acc) do
    case Sqlite3.multi_step(conn, statement, 200) do
      {:rows, rows} when length(acc) + length(rows) < limit ->
        fetch_rows(conn, statement, limit, acc ++ rows)

      {_rows_or_done, rows} when is_list(rows) ->
        {:ok, acc ++ rows}

      {:error, message} ->
        {:error, message}

      :busy ->
        {:error, "database busy"}
    end
  end

  defp sql_error(message, window) do
    cond do
      message =~ "not authorized" ->
        Error.new(:read_only, "Porthole is read-only: only SELECT queries are allowed")

      window == nil and message =~ ~r/no such column: \S*_delta/ ->
        Error.new(
          :window_required,
          "#{message}: _delta columns only exist when sampling, pass window_ms (e.g. 5000)"
        )

      message =~ "no such table" ->
        Error.new(
          :sql_error,
          "#{message}. Tables: #{Enum.map_join(Table.all(), ", ", & &1.name())}"
        )

      true ->
        Error.new(:sql_error, message)
    end
  end

  defp sql_type(:text), do: "TEXT"
  defp sql_type(_integer_or_boolean), do: "INTEGER"

  defp sql_value(true), do: 1
  defp sql_value(false), do: 0
  defp sql_value(value), do: value

  defp shorten_cells(rows) do
    Enum.map_reduce(rows, 0, fn row, count ->
      Enum.map_reduce(row, count, fn
        text, count when is_binary(text) and byte_size(text) > @max_cell_bytes ->
          {Term.truncate(text, @max_cell_bytes), count + 1}

        value, count ->
          {value, count}
      end)
    end)
  end
end
