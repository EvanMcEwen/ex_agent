defmodule ExAgent.ToolExecutor do
  @moduledoc false

  require Logger

  alias ExAgent.ToolProvider
  alias ReqLLM.ToolCall

  @spec execute_tool_calls([ToolCall.t()], ToolProvider.t(), ExAgent.Memory.t()) ::
          ExAgent.Memory.t()
  def execute_tool_calls(tool_calls, provider, memory) do
    results =
      Enum.map(tool_calls, fn call ->
        name = ToolCall.name(call)
        args = ToolCall.args_map(call) || %{}

        Logger.debug("[ExAgent] tool_call name=#{name} args=#{inspect(args)}")

        result =
          case ToolProvider.execute(provider, name, args) do
            {:ok, value} -> value
            {:error, reason} -> "Tool error: #{inspect(reason)}"
          end

        Logger.debug("[ExAgent] tool_result name=#{name} result=#{inspect(result)}")

        {call.id, name, result}
      end)

    ExAgent.Memory.append_tool_results(memory, tool_calls, results)
  end
end
