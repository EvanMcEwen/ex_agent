defmodule ExAgent.Tools.TodoTest do
  use ExUnit.Case, async: true

  alias ExAgent.TodoStore
  alias ExAgent.TodoStore.InMemory
  alias ExAgent.Tools.Todo

  defp new_tools do
    {:ok, store} = TodoStore.new(InMemory)
    {store, Todo.tools(store)}
  end

  defp find_tool(tools, name), do: Enum.find(tools, &(&1.name == name))

  describe "tools/1" do
    test "returns four tools" do
      {_store, tools} = new_tools()
      assert length(tools) == 4
    end

    test "includes the expected tool names" do
      {_store, tools} = new_tools()
      names = Enum.map(tools, & &1.name)
      assert "todo_create" in names
      assert "todo_list" in names
      assert "todo_update" in names
      assert "todo_delete" in names
    end
  end

  describe "todo_create tool" do
    test "creates a todo with required content" do
      {_store, tools} = new_tools()
      tool = find_tool(tools, "todo_create")
      assert {:ok, todo} = ReqLLM.Tool.execute(tool, %{"content" => "Buy groceries"})
      assert todo.content == "Buy groceries"
      assert todo.tags == []
      assert todo.done == false
      assert is_binary(todo.id) and todo.id != ""
    end

    test "creates a todo with tags" do
      {_store, tools} = new_tools()
      tool = find_tool(tools, "todo_create")
      assert {:ok, todo} = ReqLLM.Tool.execute(tool, %{"content" => "Task", "tags" => ["shopping"]})
      assert todo.tags == ["shopping"]
    end

    test "defaults to no tags when omitted" do
      {_store, tools} = new_tools()
      tool = find_tool(tools, "todo_create")
      assert {:ok, todo} = ReqLLM.Tool.execute(tool, %{"content" => "Task"})
      assert todo.tags == []
    end
  end

  describe "todo_list tool" do
    test "returns empty list when no todos exist" do
      {_store, tools} = new_tools()
      tool = find_tool(tools, "todo_list")
      assert {:ok, []} = ReqLLM.Tool.execute(tool, %{})
    end

    test "returns all todos when no tag filter" do
      {store, tools} = new_tools()
      TodoStore.create(store, "First", [])
      TodoStore.create(store, "Second", [])
      tool = find_tool(tools, "todo_list")
      assert {:ok, todos} = ReqLLM.Tool.execute(tool, %{})
      assert length(todos) == 2
    end

    test "filters todos by tag" do
      {store, tools} = new_tools()
      TodoStore.create(store, "Shopping item", ["shopping"])
      TodoStore.create(store, "Work item", ["work"])
      tool = find_tool(tools, "todo_list")
      assert {:ok, todos} = ReqLLM.Tool.execute(tool, %{"tag" => "shopping"})
      assert length(todos) == 1
      assert hd(todos).content == "Shopping item"
    end
  end

  describe "todo_update tool" do
    test "marks a todo as done" do
      {store, tools} = new_tools()
      {:ok, todo} = TodoStore.create(store, "Task", [])
      tool = find_tool(tools, "todo_update")
      assert {:ok, updated} = ReqLLM.Tool.execute(tool, %{"id" => todo.id, "done" => true})
      assert updated.done == true
    end

    test "updates content" do
      {store, tools} = new_tools()
      {:ok, todo} = TodoStore.create(store, "Old", [])
      tool = find_tool(tools, "todo_update")
      assert {:ok, updated} = ReqLLM.Tool.execute(tool, %{"id" => todo.id, "content" => "New"})
      assert updated.content == "New"
    end

    test "updates tags" do
      {store, tools} = new_tools()
      {:ok, todo} = TodoStore.create(store, "Task", ["old"])
      tool = find_tool(tools, "todo_update")
      assert {:ok, updated} = ReqLLM.Tool.execute(tool, %{"id" => todo.id, "tags" => ["new"]})
      assert updated.tags == ["new"]
    end

    test "returns error for unknown id" do
      {_store, tools} = new_tools()
      tool = find_tool(tools, "todo_update")
      assert {:error, :not_found} = ReqLLM.Tool.execute(tool, %{"id" => "nonexistent", "done" => true})
    end

    test "update is reflected in subsequent list calls" do
      {store, tools} = new_tools()
      {:ok, todo} = TodoStore.create(store, "Task", [])
      update_tool = find_tool(tools, "todo_update")
      list_tool = find_tool(tools, "todo_list")
      ReqLLM.Tool.execute(update_tool, %{"id" => todo.id, "done" => true})
      assert {:ok, [listed]} = ReqLLM.Tool.execute(list_tool, %{})
      assert listed.done == true
    end
  end

  describe "todo_delete tool" do
    test "removes the todo" do
      {store, tools} = new_tools()
      {:ok, todo} = TodoStore.create(store, "Task", [])
      tool = find_tool(tools, "todo_delete")
      assert :ok = ReqLLM.Tool.execute(tool, %{"id" => todo.id})
      assert {:ok, []} = TodoStore.list(store)
    end

    test "returns error for unknown id" do
      {_store, tools} = new_tools()
      tool = find_tool(tools, "todo_delete")
      assert {:error, :not_found} = ReqLLM.Tool.execute(tool, %{"id" => "nonexistent"})
    end

    test "delete is reflected in subsequent list calls" do
      {_store, tools} = new_tools()
      create_tool = find_tool(tools, "todo_create")
      list_tool = find_tool(tools, "todo_list")
      delete_tool = find_tool(tools, "todo_delete")

      {:ok, todo} = ReqLLM.Tool.execute(create_tool, %{"content" => "Task"})
      ReqLLM.Tool.execute(delete_tool, %{"id" => todo.id})
      assert {:ok, []} = ReqLLM.Tool.execute(list_tool, %{})
    end
  end
end
