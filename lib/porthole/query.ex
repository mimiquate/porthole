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
      # In a process of its own: a query briefly holds a lot of data, and a
      # long-lived caller (an HTTP connection) would otherwise keep the heap
      # it grew to.
      result = fn -> do_run(sql, opts) end |> Task.async() |> Task.await(:infinity)
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
    # A query on the schema lists every table (agents check what they can
    # query), but only the tables a query names are collected: the others
    # are created empty.
    listed = if sql =~ ~r/\bsqlite_(master|schema)\b/i, do: Table.all() -- tables, else: []
    {:ok, conn} = Sqlite3.open(":memory:")

    try do
      {cuts, errors} = load(conn, tables, listed, nodes, window, policy, all_supervisors)

      with {:ok, columns, rows, more?} <- execute(conn, sql, window, policy) do
        {rows, shortened} = shorten_cells(rows)

        notes =
          List.flatten([
            if(more?, do: "only the first #{policy.max_result_rows} rows are returned", else: []),
            if(listed != [],
              do:
                "the schema lists every table, but only the tables a query names are " <>
                  "collected: #{Enum.map_join(listed, ", ", & &1.name())} are empty here " <>
                  "(name a table in a query to collect it)",
              else: []
            ),
            if(shortened > 0,
              do: "#{shortened} cells were cut to #{@max_cell_bytes} bytes",
              else: []
            ),
            for({name, node, cut} <- Enum.reverse(cuts), do: cut_note(name, node, cut, policy))
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
    after
      Sqlite3.close(conn)
    end
  end

  defp cut_note(name, node, {:rows, loaded}, policy),
    do:
      "#{name} on #{node}: collection stopped at #{policy.max_rows} rows (max_rows), " <>
        "#{loaded} loaded; aggregates are incomplete"

  defp cut_note(name, node, {:bytes, loaded}, policy),
    do:
      "#{name} on #{node}: only #{loaded} rows were loaded, this node's share of the " <>
        "query's #{policy.max_bytes}-byte budget (max_bytes); aggregates are incomplete"

  # Collects the tables and loads them into SQLite node by node, as each node
  # answers, so the rows of only one node are held at a time. Every node and
  # table gets an equal share of the policy's max_bytes; rows beyond a share
  # are not loaded. Returns the cuts and the nodes that failed.
  defp load(conn, tables, listed, nodes, window, policy, all_supervisors) do
    :ok = Sqlite3.execute(conn, "BEGIN")
    inserts = Map.new(tables, &{&1, create_table(conn, &1, window != nil)})

    for table <- listed do
      {statement, _columns} = create_table(conn, table, window != nil)
      Sqlite3.release(conn, statement)
    end

    share = div(policy.max_bytes, max(length(nodes) * length(tables), 1))
    limits = %{max_rows: policy.max_rows, all_supervisors: all_supervisors}

    {cuts, errors} =
      Collector.reduce(
        nodes,
        Enum.map(tables, & &1.name()),
        window,
        limits,
        policy.timeout_ms,
        [],
        fn
          node, table, rows, truncated, cuts ->
            {statement, columns} = inserts[table]

            case insert(conn, statement, columns, Atom.to_string(node), rows, share) do
              {:all, loaded} when truncated == :rows ->
                [{table.name(), node, {:rows, loaded}} | cuts]

              {:all, _loaded} ->
                cuts

              {:cut, loaded} ->
                [{table.name(), node, {:bytes, loaded}} | cuts]
            end
        end
      )

    Enum.each(inserts, fn {_table, {statement, _}} -> Sqlite3.release(conn, statement) end)
    :ok = Sqlite3.execute(conn, "COMMIT")
    :ok = Sqlite3.set_authorizer(conn, @deny)
    {cuts, errors}
  end

  defp create_table(conn, table, sampled?) do
    columns = [{:node, :text, ""} | Table.columns(table, sampled?)]

    definitions =
      Enum.map_join(columns, ", ", fn {name, type, _doc} -> ~s("#{name}" #{sql_type(type)}) end)

    placeholders = Enum.map_join(columns, ", ", fn _ -> "?" end)
    :ok = Sqlite3.execute(conn, ~s[CREATE TABLE "#{table.name()}" (#{definitions})])

    {:ok, statement} =
      Sqlite3.prepare(conn, ~s[INSERT INTO "#{table.name()}" VALUES (#{placeholders})])

    {statement, for({name, _, _} <- tl(columns), do: name)}
  end

  # Inserts rows until `budget` bytes are loaded.
  defp insert(conn, statement, columns, node, rows, budget) do
    Enum.reduce_while(rows, {:all, 0, 0}, fn row, {:all, loaded, bytes} ->
      values = [node | Enum.map(columns, &sql_value(row[&1]))]
      bytes = bytes + Enum.reduce(values, 0, &(value_bytes(&1) + &2))

      if bytes > budget do
        {:halt, {:cut, loaded, bytes}}
      else
        :ok = Sqlite3.bind(statement, values)
        :done = Sqlite3.step(conn, statement)
        {:cont, {:all, loaded + 1, bytes}}
      end
    end)
    |> then(fn {status, loaded, _bytes} -> {status, loaded} end)
  end

  defp value_bytes(value) when is_binary(value), do: byte_size(value)
  defp value_bytes(_number_or_nil), do: 8

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

  defp execute(conn, sql, window, policy) do
    case Sqlite3.prepare(conn, sql) do
      {:ok, statement} -> fetch(conn, statement, policy)
      {:error, message} -> {:error, sql_error(message, window)}
    end
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
