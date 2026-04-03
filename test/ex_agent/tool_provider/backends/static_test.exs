defmodule ExAgent.ToolProvider.StaticTest do
  use ExUnit.Case, async: true

  alias ExAgent.ToolProvider
  alias ExAgent.ToolProvider.Static

  defp make_tool(name, callback) do
    ReqLLM.Tool.new!(
      name: name,
      description: "Test tool: #{name}",
      parameter_schema: [],
      callback: callback
    )
  end

  describe "init/1" do
    test "initializes with empty tools list by default" do
      assert {:ok, {tools, index}} = Static.init([])
      assert tools == []
      assert index == %{}
    end

    test "initializes with provided tools" do
      tool = make_tool("my_tool", fn _args -> {:ok, "result"} end)
      assert {:ok, {tools, index}} = Static.init(tools: [tool])
      assert tools == [tool]
      assert Map.has_key?(index, "my_tool")
    end

    test "indexes multiple tools by name" do
      tool_a = make_tool("tool_a", fn _ -> {:ok, "a"} end)
      tool_b = make_tool("tool_b", fn _ -> {:ok, "b"} end)
      assert {:ok, {tools, index}} = Static.init(tools: [tool_a, tool_b])
      assert length(tools) == 2
      assert Map.has_key?(index, "tool_a")
      assert Map.has_key?(index, "tool_b")
    end
  end

  describe "list_tools/1" do
    test "returns empty list when no tools" do
      {:ok, state} = Static.init([])
      assert Static.list_tools(state) == []
    end

    test "returns all registered tools" do
      tool1 = make_tool("t1", fn _ -> {:ok, 1} end)
      tool2 = make_tool("t2", fn _ -> {:ok, 2} end)
      {:ok, state} = Static.init(tools: [tool1, tool2])
      assert Static.list_tools(state) == [tool1, tool2]
    end

    test "preserves insertion order" do
      tools = for i <- 1..5, do: make_tool("tool_#{i}", fn _ -> {:ok, i} end)
      {:ok, state} = Static.init(tools: tools)
      assert Static.list_tools(state) == tools
    end
  end

  describe "execute/3" do
    test "calls the tool callback on success" do
      tool = make_tool("add_one", fn %{"n" => n} -> {:ok, n + 1} end)
      {:ok, state} = Static.init(tools: [tool])
      assert {:ok, 6} = Static.execute(state, "add_one", %{"n" => 5})
    end

    test "returns {:error, reason} when callback returns error" do
      tool = make_tool("fail_tool", fn _ -> {:error, :something_went_wrong} end)
      {:ok, state} = Static.init(tools: [tool])
      assert {:error, :something_went_wrong} = Static.execute(state, "fail_tool", %{})
    end

    test "returns {:error, message} for unknown tool name" do
      {:ok, state} = Static.init([])
      assert {:error, "Unknown tool 'nonexistent'"} = Static.execute(state, "nonexistent", %{})
    end

    test "unknown tool error message includes the tool name" do
      {:ok, state} = Static.init([])
      {:error, msg} = Static.execute(state, "missing_tool", %{})
      assert msg =~ "missing_tool"
    end

    test "passes args map to callback" do
      tool = make_tool("echo", fn args -> {:ok, args} end)
      {:ok, state} = Static.init(tools: [tool])
      args = %{"key" => "value", "count" => 3}
      assert {:ok, ^args} = Static.execute(state, "echo", args)
    end
  end

  describe "ToolProvider wrapper delegation" do
    test "new/2 initializes backend" do
      assert {:ok, provider} = ToolProvider.new(Static, [])
      assert provider.backend == Static
    end

    test "new/2 returns error when backend init fails" do
      defmodule FailingProvider do
        @behaviour ExAgent.ToolProvider
        def init(_), do: {:error, :bad_config}
        def list_tools(_), do: []
        def execute(_, _, _), do: {:error, :not_implemented}
      end

      assert {:error, :bad_config} = ToolProvider.new(FailingProvider, [])
    end

    test "list_tools/1 delegates to backend" do
      tool = make_tool("t", fn _ -> {:ok, :ok} end)
      {:ok, provider} = ToolProvider.new(Static, tools: [tool])
      assert ToolProvider.list_tools(provider) == [tool]
    end

    test "execute/3 delegates to backend on success" do
      tool = make_tool("greet", fn %{"name" => n} -> {:ok, "Hello, #{n}!"} end)
      {:ok, provider} = ToolProvider.new(Static, tools: [tool])
      assert {:ok, "Hello, World!"} = ToolProvider.execute(provider, "greet", %{"name" => "World"})
    end

    test "execute/3 delegates to backend on unknown tool" do
      {:ok, provider} = ToolProvider.new(Static, [])
      assert {:error, _} = ToolProvider.execute(provider, "unknown", %{})
    end
  end
end
