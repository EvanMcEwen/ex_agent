defmodule ExAgent.Agent do
  @moduledoc """
  Agent configuration struct.

  Defines the model, system prompt, tools, and behavior parameters
  for an agent. Pass this to `ExAgent.start/1` to spawn a GenServer process.

  ## Example

      agent = %ExAgent.Agent{
        name: "researcher",
        model: "anthropic:claude-sonnet-4-20250514",
        system_prompt: "You are a research assistant.",
        tools: [weather_tool],
        max_turns: 20
      }

      {:ok, pid} = ExAgent.start(agent)
  """

  @type t :: %__MODULE__{
          name: atom() | String.t() | nil,
          model: String.t(),
          system_prompt: String.t() | nil,
          tools: [ReqLLM.Tool.t()],
          max_turns: pos_integer(),
          timeout: pos_integer(),
          generate_opts: keyword(),
          metadata: map()
        }

  @enforce_keys [:model]
  defstruct [
    :name,
    :model,
    :system_prompt,
    tools: [],
    max_turns: 10,
    timeout: 120_000,
    generate_opts: [],
    metadata: %{}
  ]
end
