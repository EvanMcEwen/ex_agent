defmodule ExAgent.ToolProvider.Static do
  @moduledoc """
  Default tool provider that wraps a static list of `ReqLLM.Tool.t()` structs.

  This is the backend used when you set `tools:` directly on `ExAgent.Agent`.
  Tool definitions and their execute functions are provided up-front at agent
  construction time and do not change across turns.

  ## Options

    * `:tools` — list of `ReqLLM.Tool.t()` structs (default `[]`)
  """

  @behaviour ExAgent.ToolProvider

  alias ReqLLM.Tool

  @impl true
  def init(opts) do
    tools = Keyword.get(opts, :tools, [])
    index = Map.new(tools, &{&1.name, &1})
    {:ok, {tools, index}}
  end

  @impl true
  def list_tools({tools, _index}), do: tools

  @impl true
  def execute({_tools, index}, name, args) do
    case Map.fetch(index, name) do
      {:ok, tool} -> Tool.execute(tool, args)
      :error -> {:error, "Unknown tool '#{name}'"}
    end
  end
end
