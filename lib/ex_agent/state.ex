defmodule ExAgent.State do
  @moduledoc false

  @type status :: :idle | :running | :completed | :error | :max_turns_exceeded

  @type t :: %__MODULE__{
          agent: ExAgent.Agent.t(),
          status: status(),
          memory: ExAgent.Memory.t(),
          tool_provider: ExAgent.ToolProvider.t(),
          turns: non_neg_integer(),
          usage: map(),
          error: term() | nil,
          caller: {pid(), reference()} | nil,
          task_ref: reference() | nil,
          timer_ref: reference() | nil,
          stream?: boolean()
        }

  defstruct [
    :agent,
    :memory,
    :tool_provider,
    :error,
    :caller,
    :task_ref,
    :timer_ref,
    status: :idle,
    turns: 0,
    usage: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, reasoning_tokens: 0, total_cost: 0.0},
    stream?: false
  ]

  @spec new(ExAgent.Agent.t()) :: t()
  def new(%ExAgent.Agent{} = agent) do
    {:ok, memory} = ExAgent.Memory.new(agent.memory_backend, agent.memory_opts)

    memory =
      if agent.system_prompt do
        ExAgent.Memory.add_system_prompt(memory, agent.system_prompt)
      else
        memory
      end

    provider_opts = Keyword.put_new(agent.tool_provider_opts, :tools, agent.tools)
    {:ok, tool_provider} = ExAgent.ToolProvider.new(agent.tool_provider, provider_opts)

    %__MODULE__{agent: agent, memory: memory, tool_provider: tool_provider}
  end

  @spec snapshot(t()) :: map()
  def snapshot(%__MODULE__{} = state) do
    %{
      name: state.agent.name,
      status: state.status,
      turns: state.turns,
      usage: state.usage,
      error: state.error,
      message_count: ExAgent.Memory.message_count(state.memory)
    }
  end
end
