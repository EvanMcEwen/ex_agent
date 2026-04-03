defmodule ExAgent.ToolExecutorTest do
  use ExUnit.Case, async: true

  alias ExAgent.{Memory, ToolExecutor, ToolProvider}
  alias ExAgent.ToolProvider.Static
  alias ReqLLM.{Context, ToolCall}

  defp new_memory do
    {:ok, mem} = Memory.new(ExAgent.Memory.InMemory, [])
    mem
  end

  defp new_provider(tools) do
    {:ok, provider} = ToolProvider.new(Static, tools: tools)
    provider
  end

  defp make_tool(name, callback) do
    ReqLLM.Tool.new!(
      name: name,
      description: "Test tool",
      parameter_schema: [],
      callback: callback
    )
  end

  describe "execute_tool_calls/3" do
    test "executes a single tool call and appends the result to memory" do
      tool = make_tool("reverse", fn %{"text" => t} -> {:ok, String.reverse(t)} end)
      provider = new_provider([tool])
      memory = new_memory()
      call = ToolCall.new("call-1", "reverse", ~s({"text":"hello"}))

      memory = ToolExecutor.execute_tool_calls([call], provider, memory)

      messages = memory |> Memory.to_context() |> Context.to_list()
      assert length(messages) == 1
      [msg] = messages
      assert msg.role == :tool
      assert msg.tool_call_id == "call-1"
    end

    test "result text appears in the tool message content" do
      tool = make_tool("greet", fn _ -> {:ok, "Hello!"} end)
      provider = new_provider([tool])
      memory = new_memory()
      call = ToolCall.new("c1", "greet", "{}")

      memory = ToolExecutor.execute_tool_calls([call], provider, memory)
      messages = memory |> Memory.to_context() |> Context.to_list()
      [msg] = messages
      text = Enum.map_join(msg.content, "", & &1.text)
      assert text =~ "Hello!"
    end

    test "executes multiple tool calls and appends all results" do
      tool_a = make_tool("double", fn %{"n" => n} -> {:ok, n * 2} end)
      tool_b = make_tool("negate", fn %{"n" => n} -> {:ok, -n} end)
      provider = new_provider([tool_a, tool_b])
      memory = new_memory()
      call1 = ToolCall.new("c1", "double", ~s({"n":5}))
      call2 = ToolCall.new("c2", "negate", ~s({"n":3}))

      memory = ToolExecutor.execute_tool_calls([call1, call2], provider, memory)

      assert Memory.message_count(memory) == 2
      messages = memory |> Memory.to_context() |> Context.to_list()
      tool_call_ids = Enum.map(messages, & &1.tool_call_id)
      assert "c1" in tool_call_ids
      assert "c2" in tool_call_ids
    end

    test "empty tool calls list returns memory unchanged" do
      provider = new_provider([])
      memory = new_memory()

      result_memory = ToolExecutor.execute_tool_calls([], provider, memory)

      assert Memory.message_count(result_memory) == 0
    end

    test "tool error is serialized as an error string in the result" do
      tool = make_tool("broken", fn _ -> {:error, :internal_error} end)
      provider = new_provider([tool])
      memory = new_memory()
      call = ToolCall.new("c1", "broken", "{}")

      memory = ToolExecutor.execute_tool_calls([call], provider, memory)

      messages = memory |> Memory.to_context() |> Context.to_list()
      [msg] = messages
      text = Enum.map_join(msg.content, "", & &1.text)
      assert text =~ "Tool error"
      assert text =~ "internal_error"
    end

    test "unknown tool name produces an error string in the result" do
      provider = new_provider([])
      memory = new_memory()
      call = ToolCall.new("c1", "nonexistent_tool", "{}")

      memory = ToolExecutor.execute_tool_calls([call], provider, memory)

      messages = memory |> Memory.to_context() |> Context.to_list()
      [msg] = messages
      text = Enum.map_join(msg.content, "", & &1.text)
      assert text =~ "Tool error"
    end

    test "handles tool call with invalid JSON args gracefully" do
      # args_map returns nil for bad JSON, ToolExecutor falls back to %{}
      tool = make_tool("accepts_empty", fn args ->
        assert args == %{}
        {:ok, "got empty args"}
      end)
      provider = new_provider([tool])
      memory = new_memory()
      # Deliberately malformed JSON
      call = ToolCall.new("c1", "accepts_empty", "not-json-at-all")

      memory = ToolExecutor.execute_tool_calls([call], provider, memory)

      # Should still produce a result message (no crash)
      assert Memory.message_count(memory) == 1
    end

    test "preserves existing messages in memory when appending results" do
      tool = make_tool("simple", fn _ -> {:ok, "done"} end)
      provider = new_provider([tool])

      # Pre-populate memory with a user message
      memory =
        new_memory()
        |> Memory.append_user("Please run a tool.")

      call = ToolCall.new("c1", "simple", "{}")
      memory = ToolExecutor.execute_tool_calls([call], provider, memory)

      messages = memory |> Memory.to_context() |> Context.to_list()
      assert length(messages) == 2
      assert hd(messages).role == :user
      assert List.last(messages).role == :tool
    end
  end
end
