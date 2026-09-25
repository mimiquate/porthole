defmodule Porthole.Audit do
  @moduledoc """
  The audit trail of what agents looked at.

  Every query that comes through a front door (MCP over HTTP or stdio) is
  recorded as one JSON object:

      {"at": "2026-09-25T16:11:40.008Z", "client": "oncall", "remote_ip": "10.0.3.7",
       "sql": "SELECT ...", "nodes": ["app@10.0.1.12"], "window_ms": 10000,
       "status": "ok", "rows": 3, "truncated": false, "error": null, "duration_ms": 10042}

  By default records are logged at `:info` level (prefixed `porthole.audit`),
  so they go wherever your logs go. To send them elsewhere, configure a
  function receiving the record map:

      config :porthole, :audit, {MyApp.Audit, :record, []}

  """

  require Logger

  @type entry :: %{
          at: String.t(),
          client: String.t(),
          remote_ip: String.t() | nil,
          sql: String.t(),
          nodes: [String.t()] | String.t() | nil,
          window_ms: pos_integer() | nil,
          status: String.t(),
          rows: non_neg_integer() | nil,
          truncated: boolean() | nil,
          error: String.t() | nil,
          duration_ms: non_neg_integer()
        }

  @doc false
  @spec record(map(), String.t(), keyword(), term(), non_neg_integer()) :: :ok
  def record(context, sql, opts, outcome, duration_ms) do
    base = %{
      at: DateTime.utc_now() |> DateTime.to_iso8601(),
      client: context.client,
      remote_ip: context[:remote_ip],
      sql: sql,
      nodes: nodes(opts[:nodes]),
      window_ms: opts[:window_ms],
      duration_ms: duration_ms
    }

    record =
      case outcome do
        {:ok, result} ->
          Map.merge(base, %{
            status: "ok",
            rows: length(result.rows),
            truncated: result.truncated,
            error: nil
          })

        {:error, error} ->
          Map.merge(base, %{
            status: "error",
            rows: nil,
            truncated: nil,
            error: "#{error.reason}: #{error.message}"
          })
      end

    case Application.get_env(:porthole, :audit, :logger) do
      :logger -> Logger.info("porthole.audit " <> JSON.encode!(record))
      {module, function, args} -> apply(module, function, [record | args])
    end

    :ok
  end

  defp nodes(nil), do: nil
  defp nodes(:all), do: "all"
  defp nodes(nodes), do: Enum.map(nodes, &to_string/1)
end
