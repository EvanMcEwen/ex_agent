defmodule ExAgent.Tools.TodoTest do
  use ExUnit.Case, async: true

  alias ExAgent.Tools.Todo.Store.InMemory
  alias ExAgent.Tools.Todo

  defp new_tools, do: Todo.tools(InMemory)

  defp find_tool(tools, name), do: Enum.find(tools, &(&1.name == name))

  defp execute(tools, name, args \\ %{}) do
    ReqLLM.Tool.execute(find_tool(tools, name), args)
  end

  defp create!(tools, content, extra \\ %{}) do
    {:ok, json} = execute(tools, "todo_create", Map.merge(%{"content" => content}, extra))
    Jason.decode!(json)
  end

  defp list!(tools, args \\ %{}) do
    {:ok, json} = execute(tools, "todo_list", args)
    Jason.decode!(json)
  end

  describe "tools/1" do
    test "returns four tools" do
      assert length(new_tools()) == 4
    end

    test "includes the expected tool names" do
      names = Enum.map(new_tools(), & &1.name)
      assert "todo_create" in names
      assert "todo_list" in names
      assert "todo_update" in names
      assert "todo_delete" in names
    end
  end

  describe "todo_create tool" do
    test "creates a todo with required content" do
      todo = create!(new_tools(), "Buy groceries")
      assert todo["content"] == "Buy groceries"
      assert todo["tags"] == []
      assert todo["done"] == false
      assert is_binary(todo["id"]) and todo["id"] != ""
    end

    test "creates a todo with tags" do
      todo = create!(new_tools(), "Task", %{"tags" => ["shopping"]})
      assert todo["tags"] == ["shopping"]
    end

    test "defaults to no tags when omitted" do
      todo = create!(new_tools(), "Task")
      assert todo["tags"] == []
    end
  end

  describe "todo_list tool" do
    test "returns empty list when no todos exist" do
      assert list!(new_tools()) == []
    end

    test "returns all todos when no tag filter" do
      tools = new_tools()
      create!(tools, "First")
      create!(tools, "Second")
      assert length(list!(tools)) == 2
    end

    test "filters todos by tag" do
      tools = new_tools()
      create!(tools, "Shopping item", %{"tags" => ["shopping"]})
      create!(tools, "Work item", %{"tags" => ["work"]})
      todos = list!(tools, %{"tag" => "shopping"})
      assert length(todos) == 1
      assert hd(todos)["content"] == "Shopping item"
    end
  end

  describe "todo_update tool" do
    test "marks a todo as done" do
      tools = new_tools()
      todo = create!(tools, "Task")
      {:ok, json} = execute(tools, "todo_update", %{"id" => todo["id"], "done" => true})
      assert Jason.decode!(json)["done"] == true
    end

    test "updates content" do
      tools = new_tools()
      todo = create!(tools, "Old")
      {:ok, json} = execute(tools, "todo_update", %{"id" => todo["id"], "content" => "New"})
      assert Jason.decode!(json)["content"] == "New"
    end

    test "updates tags" do
      tools = new_tools()
      todo = create!(tools, "Task", %{"tags" => ["old"]})
      {:ok, json} = execute(tools, "todo_update", %{"id" => todo["id"], "tags" => ["new"]})
      assert Jason.decode!(json)["tags"] == ["new"]
    end

    test "returns error for unknown id" do
      tools = new_tools()
      assert {:error, :not_found} = execute(tools, "todo_update", %{"id" => "nonexistent", "done" => true})
    end

    test "update is reflected in subsequent list calls" do
      tools = new_tools()
      todo = create!(tools, "Task")
      execute(tools, "todo_update", %{"id" => todo["id"], "done" => true})
      [listed] = list!(tools)
      assert listed["done"] == true
    end
  end

  describe "todo_delete tool" do
    test "removes the todo" do
      tools = new_tools()
      todo = create!(tools, "Task")
      assert {:ok, _} = execute(tools, "todo_delete", %{"id" => todo["id"]})
      assert list!(tools) == []
    end

    test "returns error for unknown id" do
      tools = new_tools()
      assert {:error, :not_found} = execute(tools, "todo_delete", %{"id" => "nonexistent"})
    end

    test "delete is reflected in subsequent list calls" do
      tools = new_tools()
      todo = create!(tools, "Task")
      execute(tools, "todo_delete", %{"id" => todo["id"]})
      assert list!(tools) == []
    end
  end
end
