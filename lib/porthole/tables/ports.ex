defmodule Porthole.Tables.Ports do
  @moduledoc """
  One row per port: sockets, files, spawned OS processes and drivers.

  Sockets opened with `:gen_tcp`/`:gen_udp` (the default `inet` backend) are
  ports and show their addresses. Sockets from the NIF-based `:socket` module
  are not ports and do not appear here.
  """

  @behaviour Porthole.Table

  alias Porthole.{Table, Term}

  @impl true
  def name, do: "ports"

  @impl true
  def description,
    do:
      "One row per port (TCP/UDP sockets, files, OS processes): owner, driver, addresses, bytes, queue."

  @impl true
  def key, do: :port

  @impl true
  def deltas, do: [:input, :output, :queue_size]

  @impl true
  def columns do
    [
      {:port, :text, "e.g. #Port<0.16>"},
      {:name, :text,
       "Driver or command: tcp_inet, udp_inet, efile, forker, or the spawned command."},
      {:owner, :text, "Connected process (join with processes.pid)."},
      {:local_address, :text, "ip:port for sockets."},
      {:remote_address, :text, "ip:port of the peer for connected sockets."},
      {:os_pid, :integer, "OS pid for spawned executables."},
      {:input, :integer, "Bytes read."},
      {:output, :integer, "Bytes written."},
      {:queue_size, :integer, "Bytes queued in the driver, waiting to be written."},
      {:memory, :integer, "Bytes."}
    ]
  end

  @impl true
  def collect(max_rows) do
    {ports, truncated} = Table.take(Port.list(), max_rows)
    {Enum.flat_map(ports, &row/1), truncated}
  end

  # A port closed mid-walk returns nil from Port.info/1,2.
  defp row(port) do
    with info when is_list(info) <- Port.info(port),
         {:memory, memory} <- Port.info(port, :memory),
         {:queue_size, queue_size} <- Port.info(port, :queue_size) do
      name = List.to_string(info[:name])
      socket? = name in ["tcp_inet", "udp_inet", "sctp_inet"]

      [
        %{
          port: inspect(port),
          name: Term.truncate(name, 200),
          owner: inspect(info[:connected]),
          local_address: if(socket?, do: address(:inet.sockname(port))),
          remote_address: if(socket?, do: address(:inet.peername(port))),
          os_pid: if(is_integer(info[:os_pid]), do: info[:os_pid]),
          input: info[:input],
          output: info[:output],
          queue_size: queue_size,
          memory: memory
        }
      ]
    else
      _closed -> []
    end
  end

  defp address({:ok, {ip, port}}), do: "#{:inet.ntoa(ip)}:#{port}"
  defp address(_error), do: nil
end
