defmodule PortholeSidecar.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    config = PortholeSidecar.Config.from_env!()

    children = [
      {PortholeSidecar.Cluster, config},
      {Porthole.Server,
       [
         port: config.port,
         ip: config.ip,
         tokens: config.tokens,
         # Resolved on every query, so the node set follows the cluster.
         query_opts: [nodes: &PortholeSidecar.Cluster.nodes/0]
       ] ++ config.tls}
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: PortholeSidecar.Supervisor)
  end
end
