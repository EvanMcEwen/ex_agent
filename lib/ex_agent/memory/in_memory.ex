defmodule ExAgent.Memory.InMemory do
  @moduledoc """
  Default in-memory conversation backend.

  Stores all messages in a `ReqLLM.Context.t()` and returns it unchanged when
  building context for LLM calls. This is a pure functional backend — no
  processes, no side effects.
  """

  @behaviour ExAgent.Memory

  alias ReqLLM.Context

  @impl true
  def init(_opts), do: {:ok, Context.new()}

  @impl true
  def add_system_prompt(ctx, content) do
    Context.append(ctx, Context.system(content))
  end

  @impl true
  def append_user(ctx, content) do
    Context.append(ctx, Context.user(content))
  end

  @impl true
  def append_assistant(ctx, message) do
    Context.append(ctx, message)
  end

  @impl true
  def append_tool_results(ctx, tool_calls, results) do
    result_map = Map.new(results, fn {id, name, result} -> {id, {name, result}} end)

    Enum.reduce(tool_calls, ctx, fn call, acc ->
      {name, result} = Map.fetch!(result_map, call.id)
      Context.append(acc, Context.tool_result(call.id, name, result))
    end)
  end

  @impl true
  def to_context(ctx), do: ctx

  @impl true
  def message_count(ctx), do: length(Context.to_list(ctx))
end
