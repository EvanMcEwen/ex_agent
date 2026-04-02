defmodule ExAgent.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      {Registry, keys: :unique, name: ExAgent.Registry},
      {Task.Supervisor, name: ExAgent.TaskSupervisor},
      {DynamicSupervisor, name: ExAgent.DynamicSupervisor, strategy: :one_for_one}
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: ExAgent.Supervisor)
  end
end
