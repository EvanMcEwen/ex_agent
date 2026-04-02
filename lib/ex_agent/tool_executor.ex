defmodule ExAgent.ToolExecutor do
  @moduledoc false

  require Logger

  alias ReqLLM.{Context, Tool, ToolCall}

  @spec execute_tool_calls([ToolCall.t()], [Tool.t()], ReqLLM.Context.t()) ::
          ReqLLM.Context.t()
  def execute_tool_calls(tool_calls, tools, context) do
    Enum.reduce(tool_calls, context, fn call, acc ->
      tool_name = ToolCall.name(call)
      tool = find_tool(tools, tool_name)
      args = ToolCall.args_map(call) || %{}

      Logger.debug("[ExAgent] tool_call name=#{tool_name} args=#{inspect(args)}")

      result = execute_one(tool, tool_name, args)

      Logger.debug("[ExAgent] tool_result name=#{tool_name} result=#{inspect(result)}")

      Context.append(acc, Context.tool_result(call.id, tool_name, result))
    end)
  end

  defp find_tool(tools, name) do
    Enum.find(tools, &(&1.name == name))
  end

  defp execute_one(nil, name, _args) do
    "Error: Unknown tool '#{name}'"
  end

  defp execute_one(tool, _name, args) do
    case Tool.execute(tool, args) do
      {:ok, value} -> value
      {:error, reason} -> "Tool error: #{inspect(reason)}"
    end
  end
end
