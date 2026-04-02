defmodule ExAgent.State do
  @moduledoc false

  @type status :: :idle | :running | :completed | :error | :max_turns_exceeded

  @type t :: %__MODULE__{
          agent: ExAgent.Agent.t(),
          status: status(),
          context: ReqLLM.Context.t(),
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
    :context,
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
    context =
      if agent.system_prompt do
        ReqLLM.Context.new([ReqLLM.Context.system(agent.system_prompt)])
      else
        ReqLLM.Context.new()
      end

    %__MODULE__{agent: agent, context: context}
  end

  @spec snapshot(t()) :: map()
  def snapshot(%__MODULE__{} = state) do
    %{
      name: state.agent.name,
      status: state.status,
      turns: state.turns,
      usage: state.usage,
      error: state.error,
      message_count: length(ReqLLM.Context.to_list(state.context))
    }
  end
end
