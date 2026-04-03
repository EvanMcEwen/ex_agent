defmodule ExAgent.Tools.Todo.Store.InMemoryTest do
  use ExUnit.Case, async: true

  alias ExAgent.Tools.Todo.Store
  alias ExAgent.Tools.Todo.Store.InMemory
  alias ExAgent.Tools.Todo.Item

  defp new_store do
    {:ok, store} = Store.new(InMemory)
    store
  end

  describe "start_link/1" do
    test "starts a process" do
      assert {:ok, pid} = InMemory.start_link()
      assert is_pid(pid)
      assert Process.alive?(pid)
    end

    test "accepts a name option" do
      assert {:ok, _pid} = InMemory.start_link(name: :test_todo_store)
      assert Process.whereis(:test_todo_store) != nil
    end
  end

  describe "create/3" do
    test "creates a todo with the given content" do
      store = new_store()
      assert {:ok, %Item{content: "Buy milk"}} = Store.create(store, "Buy milk", [])
    end

    test "creates a todo with tags" do
      store = new_store()
      assert {:ok, %Item{tags: ["shopping"]}} = Store.create(store, "Buy milk", ["shopping"])
    end

    test "defaults done to false" do
      store = new_store()
      assert {:ok, %Item{done: false}} = Store.create(store, "Task", [])
    end

    test "assigns a non-empty id" do
      store = new_store()
      assert {:ok, %Item{id: id}} = Store.create(store, "Task", [])
      assert is_binary(id) and id != ""
    end

    test "assigns unique ids to each todo" do
      store = new_store()
      {:ok, a} = Store.create(store, "First", [])
      {:ok, b} = Store.create(store, "Second", [])
      assert a.id != b.id
    end

    test "sets inserted_at to a DateTime" do
      store = new_store()
      assert {:ok, %Item{inserted_at: %DateTime{}}} = Store.create(store, "Task", [])
    end
  end

  describe "list/2" do
    test "returns empty list when no todos exist" do
      store = new_store()
      assert {:ok, []} = Store.list(store)
    end

    test "returns all todos when no tag filter is given" do
      store = new_store()
      Store.create(store, "First", ["a"])
      Store.create(store, "Second", ["b"])
      assert {:ok, todos} = Store.list(store)
      assert length(todos) == 2
    end

    test "filters todos by tag" do
      store = new_store()
      Store.create(store, "Shopping task", ["shopping"])
      Store.create(store, "Work task", ["work"])
      Store.create(store, "Both", ["shopping", "work"])

      assert {:ok, todos} = Store.list(store, "shopping")
      assert length(todos) == 2
      assert Enum.all?(todos, fn t -> "shopping" in t.tags end)
    end

    test "returns empty list when tag has no matching todos" do
      store = new_store()
      Store.create(store, "Task", ["other"])
      assert {:ok, []} = Store.list(store, "nonexistent")
    end

    test "returns todos sorted by inserted_at ascending" do
      store = new_store()
      Store.create(store, "First", [])
      Process.sleep(1)
      Store.create(store, "Second", [])

      assert {:ok, [first, second]} = Store.list(store)
      assert first.content == "First"
      assert second.content == "Second"
    end
  end

  describe "update/3" do
    test "updates content" do
      store = new_store()
      {:ok, todo} = Store.create(store, "Old content", [])
      assert {:ok, updated} = Store.update(store, todo.id, %{"content" => "New content"})
      assert updated.content == "New content"
    end

    test "marks a todo as done" do
      store = new_store()
      {:ok, todo} = Store.create(store, "Task", [])
      assert {:ok, updated} = Store.update(store, todo.id, %{"done" => true})
      assert updated.done == true
    end

    test "marks a todo as not done" do
      store = new_store()
      {:ok, todo} = Store.create(store, "Task", [])
      Store.update(store, todo.id, %{"done" => true})
      assert {:ok, updated} = Store.update(store, todo.id, %{"done" => false})
      assert updated.done == false
    end

    test "updates tags" do
      store = new_store()
      {:ok, todo} = Store.create(store, "Task", ["old"])
      assert {:ok, updated} = Store.update(store, todo.id, %{"tags" => ["new"]})
      assert updated.tags == ["new"]
    end

    test "accepts atom keys in the changes map" do
      store = new_store()
      {:ok, todo} = Store.create(store, "Task", [])
      assert {:ok, updated} = Store.update(store, todo.id, %{done: true})
      assert updated.done == true
    end

    test "unspecified fields are not changed" do
      store = new_store()
      {:ok, todo} = Store.create(store, "Task", ["tag1"])
      assert {:ok, updated} = Store.update(store, todo.id, %{"done" => true})
      assert updated.content == "Task"
      assert updated.tags == ["tag1"]
    end

    test "returns not_found for unknown id" do
      store = new_store()
      assert {:error, :not_found} = Store.update(store, "nonexistent", %{"done" => true})
    end

    test "persists the update to future list calls" do
      store = new_store()
      {:ok, todo} = Store.create(store, "Task", [])
      Store.update(store, todo.id, %{"done" => true})
      {:ok, [listed]} = Store.list(store)
      assert listed.done == true
    end
  end

  describe "delete/2" do
    test "removes the todo from the store" do
      store = new_store()
      {:ok, todo} = Store.create(store, "Task", [])
      assert :ok = Store.delete(store, todo.id)
      assert {:ok, []} = Store.list(store)
    end

    test "only removes the targeted todo" do
      store = new_store()
      {:ok, a} = Store.create(store, "Keep", [])
      {:ok, b} = Store.create(store, "Remove", [])
      assert :ok = Store.delete(store, b.id)
      assert {:ok, [remaining]} = Store.list(store)
      assert remaining.id == a.id
    end

    test "returns not_found for unknown id" do
      store = new_store()
      assert {:error, :not_found} = Store.delete(store, "nonexistent")
    end
  end
end
