defmodule ExAgent.Memory.InMemoryTest do
  use ExUnit.Case, async: true

  alias ExAgent.Memory.InMemory
  alias ReqLLM.{Context, ToolCall}

  # Build a Memory wrapper backed by InMemory
  defp new_memory(opts \\ []) do
    {:ok, mem} = ExAgent.Memory.new(InMemory, opts)
    mem
  end

  describe "init/1" do
    test "returns {:ok, empty_context}" do
      assert {:ok, ctx} = InMemory.init([])
      assert ctx == Context.new()
    end

    test "ignores unknown opts" do
      assert {:ok, _ctx} = InMemory.init(foo: :bar)
    end
  end

  describe "add_system_prompt/2" do
    test "prepends a system message" do
      {:ok, ctx} = InMemory.init([])
      ctx = InMemory.add_system_prompt(ctx, "You are helpful.")
      [msg] = Context.to_list(ctx)
      assert msg.role == :system
    end

    test "system message text matches content" do
      {:ok, ctx} = InMemory.init([])
      ctx = InMemory.add_system_prompt(ctx, "Be concise.")
      [msg] = Context.to_list(ctx)
      assert Enum.any?(msg.content, &(&1.type == :text and &1.text == "Be concise."))
    end
  end

  describe "append_user/2" do
    test "adds a user message" do
      {:ok, ctx} = InMemory.init([])
      ctx = InMemory.append_user(ctx, "Hello!")
      [msg] = Context.to_list(ctx)
      assert msg.role == :user
    end

    test "user message preserves content" do
      {:ok, ctx} = InMemory.init([])
      ctx = InMemory.append_user(ctx, "Tell me a joke.")
      [msg] = Context.to_list(ctx)
      assert Enum.any?(msg.content, &(&1.type == :text and &1.text == "Tell me a joke."))
    end

    test "multiple user messages are appended in order" do
      {:ok, ctx} = InMemory.init([])
      ctx = InMemory.append_user(ctx, "First")
      ctx = InMemory.append_user(ctx, "Second")
      messages = Context.to_list(ctx)
      assert length(messages) == 2
      assert Enum.at(messages, 0).role == :user
      assert Enum.at(messages, 1).role == :user
    end
  end

  describe "append_assistant/2" do
    test "adds an assistant message" do
      {:ok, ctx} = InMemory.init([])
      assistant_msg = Context.assistant("Here's my response.")
      ctx = InMemory.append_assistant(ctx, assistant_msg)
      [msg] = Context.to_list(ctx)
      assert msg.role == :assistant
    end
  end

  describe "append_tool_results/3" do
    test "adds tool result messages for each tool call" do
      {:ok, ctx} = InMemory.init([])
      call = ToolCall.new("call-1", "get_weather", ~s({"location":"Paris"}))
      results = [{"call-1", "get_weather", "72°F and sunny"}]
      ctx = InMemory.append_tool_results(ctx, [call], results)

      messages = Context.to_list(ctx)
      assert length(messages) == 1
      [msg] = messages
      assert msg.role == :tool
      assert msg.tool_call_id == "call-1"
    end

    test "adds multiple tool result messages in call order" do
      {:ok, ctx} = InMemory.init([])
      call1 = ToolCall.new("call-1", "tool_a", "{}")
      call2 = ToolCall.new("call-2", "tool_b", "{}")
      results = [{"call-1", "tool_a", "result_a"}, {"call-2", "tool_b", "result_b"}]

      ctx = InMemory.append_tool_results(ctx, [call1, call2], results)
      messages = Context.to_list(ctx)
      assert length(messages) == 2
      assert Enum.at(messages, 0).tool_call_id == "call-1"
      assert Enum.at(messages, 1).tool_call_id == "call-2"
    end

    test "results can appear in any order as long as IDs match" do
      {:ok, ctx} = InMemory.init([])
      call1 = ToolCall.new("call-1", "tool_a", "{}")
      call2 = ToolCall.new("call-2", "tool_b", "{}")
      # Results in reverse order — the reducer maps by ID so order doesn't matter
      results = [{"call-2", "tool_b", "result_b"}, {"call-1", "tool_a", "result_a"}]

      ctx = InMemory.append_tool_results(ctx, [call1, call2], results)
      messages = Context.to_list(ctx)
      # Messages appear in the order the tool_calls were processed
      assert Enum.at(messages, 0).tool_call_id == "call-1"
      assert Enum.at(messages, 1).tool_call_id == "call-2"
    end

    test "raises KeyError when result ID does not match any tool call" do
      {:ok, ctx} = InMemory.init([])
      call = ToolCall.new("call-1", "tool_a", "{}")
      results = [{"call-WRONG", "tool_a", "result"}]

      assert_raise KeyError, fn ->
        InMemory.append_tool_results(ctx, [call], results)
      end
    end

    test "empty call list produces no messages" do
      {:ok, ctx} = InMemory.init([])
      ctx = InMemory.append_tool_results(ctx, [], [])
      assert Context.to_list(ctx) == []
    end
  end

  describe "to_context/1" do
    test "returns the context unchanged" do
      {:ok, ctx} = InMemory.init([])
      ctx = InMemory.append_user(ctx, "hello")
      assert InMemory.to_context(ctx) == ctx
    end
  end

  describe "message_count/1" do
    test "returns 0 for empty context" do
      {:ok, ctx} = InMemory.init([])
      assert InMemory.message_count(ctx) == 0
    end

    test "increments with each appended message" do
      {:ok, ctx} = InMemory.init([])
      assert InMemory.message_count(ctx) == 0
      ctx = InMemory.add_system_prompt(ctx, "sys")
      assert InMemory.message_count(ctx) == 1
      ctx = InMemory.append_user(ctx, "hi")
      assert InMemory.message_count(ctx) == 2
      ctx = InMemory.append_assistant(ctx, Context.assistant("hi back"))
      assert InMemory.message_count(ctx) == 3
    end
  end

  describe "full conversation lifecycle" do
    test "builds a complete multi-turn conversation in order" do
      {:ok, ctx} = InMemory.init([])
      ctx = InMemory.add_system_prompt(ctx, "You are a test bot.")
      ctx = InMemory.append_user(ctx, "Call a tool.")

      # Simulate an assistant response that triggers a tool call
      call = ToolCall.new("call-1", "do_thing", ~s({"x":1}))
      assistant_msg = Context.assistant("", tool_calls: [call])
      ctx = InMemory.append_assistant(ctx, assistant_msg)
      ctx = InMemory.append_tool_results(ctx, [call], [{"call-1", "do_thing", "done"}])
      ctx = InMemory.append_assistant(ctx, Context.assistant("All done!"))

      messages = Context.to_list(ctx)
      roles = Enum.map(messages, & &1.role)
      assert roles == [:system, :user, :assistant, :tool, :assistant]
    end
  end

  describe "Memory wrapper delegation" do
    test "new/2 initializes the backend" do
      assert {:ok, mem} = ExAgent.Memory.new(InMemory, [])
      assert mem.backend == InMemory
    end

    test "new/2 returns error when backend init fails" do
      defmodule FailingMemory do
        @behaviour ExAgent.Memory
        def init(_), do: {:error, :init_failed}
        def add_system_prompt(s, _), do: s
        def append_user(s, _), do: s
        def append_assistant(s, _), do: s
        def append_tool_results(s, _, _), do: s
        def to_context(_), do: ReqLLM.Context.new()
        def message_count(_), do: 0
      end

      assert {:error, :init_failed} = ExAgent.Memory.new(FailingMemory, [])
    end

    test "add_system_prompt delegates to backend" do
      mem = new_memory()
      mem = ExAgent.Memory.add_system_prompt(mem, "system prompt")
      messages = mem |> ExAgent.Memory.to_context() |> Context.to_list()
      assert length(messages) == 1
      assert hd(messages).role == :system
    end

    test "append_user delegates to backend" do
      mem = new_memory()
      mem = ExAgent.Memory.append_user(mem, "user msg")
      messages = mem |> ExAgent.Memory.to_context() |> Context.to_list()
      assert hd(messages).role == :user
    end

    test "append_assistant delegates to backend" do
      mem = new_memory()
      msg = Context.assistant("reply")
      mem = ExAgent.Memory.append_assistant(mem, msg)
      messages = mem |> ExAgent.Memory.to_context() |> Context.to_list()
      assert hd(messages).role == :assistant
    end

    test "append_tool_results delegates to backend" do
      mem = new_memory()
      call = ToolCall.new("c1", "tool", "{}")
      mem = ExAgent.Memory.append_tool_results(mem, [call], [{"c1", "tool", "ok"}])
      assert ExAgent.Memory.message_count(mem) == 1
    end

    test "message_count delegates to backend" do
      mem = new_memory()
      assert ExAgent.Memory.message_count(mem) == 0
      mem = ExAgent.Memory.append_user(mem, "hi")
      assert ExAgent.Memory.message_count(mem) == 1
    end
  end
end
