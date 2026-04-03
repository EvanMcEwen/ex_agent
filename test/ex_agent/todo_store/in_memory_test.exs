defmodule ExAgent.TodoStore.InMemoryTest do
  use ExUnit.Case, async: true

  alias ExAgent.TodoStore
  alias ExAgent.TodoStore.InMemory
  alias ExAgent.Todo

  defp new_store do
    {:ok, store} = TodoStore.new(InMemory)
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
      assert {:ok, %Todo{content: "Buy milk"}} = TodoStore.create(store, "Buy milk", [])
    end

    test "creates a todo with tags" do
      store = new_store()
      assert {:ok, %Todo{tags: ["shopping"]}} = TodoStore.create(store, "Buy milk", ["shopping"])
    end

    test "defaults done to false" do
      store = new_store()
      assert {:ok, %Todo{done: false}} = TodoStore.create(store, "Task", [])
    end

    test "assigns a non-empty id" do
      store = new_store()
      assert {:ok, %Todo{id: id}} = TodoStore.create(store, "Task", [])
      assert is_binary(id) and id != ""
    end

    test "assigns unique ids to each todo" do
      store = new_store()
      {:ok, a} = TodoStore.create(store, "First", [])
      {:ok, b} = TodoStore.create(store, "Second", [])
      assert a.id != b.id
    end

    test "sets inserted_at to a DateTime" do
      store = new_store()
      assert {:ok, %Todo{inserted_at: %DateTime{}}} = TodoStore.create(store, "Task", [])
    end
  end

  describe "list/2" do
    test "returns empty list when no todos exist" do
      store = new_store()
      assert {:ok, []} = TodoStore.list(store)
    end

    test "returns all todos when no tag filter is given" do
      store = new_store()
      TodoStore.create(store, "First", ["a"])
      TodoStore.create(store, "Second", ["b"])
      assert {:ok, todos} = TodoStore.list(store)
      assert length(todos) == 2
    end

    test "filters todos by tag" do
      store = new_store()
      TodoStore.create(store, "Shopping task", ["shopping"])
      TodoStore.create(store, "Work task", ["work"])
      TodoStore.create(store, "Both", ["shopping", "work"])

      assert {:ok, todos} = TodoStore.list(store, "shopping")
      assert length(todos) == 2
      assert Enum.all?(todos, fn t -> "shopping" in t.tags end)
    end

    test "returns empty list when tag has no matching todos" do
      store = new_store()
      TodoStore.create(store, "Task", ["other"])
      assert {:ok, []} = TodoStore.list(store, "nonexistent")
    end

    test "returns todos sorted by inserted_at ascending" do
      store = new_store()
      TodoStore.create(store, "First", [])
      Process.sleep(1)
      TodoStore.create(store, "Second", [])

      assert {:ok, [first, second]} = TodoStore.list(store)
      assert first.content == "First"
      assert second.content == "Second"
    end
  end

  describe "update/3" do
    test "updates content" do
      store = new_store()
      {:ok, todo} = TodoStore.create(store, "Old content", [])
      assert {:ok, updated} = TodoStore.update(store, todo.id, %{"content" => "New content"})
      assert updated.content == "New content"
    end

    test "marks a todo as done" do
      store = new_store()
      {:ok, todo} = TodoStore.create(store, "Task", [])
      assert {:ok, updated} = TodoStore.update(store, todo.id, %{"done" => true})
      assert updated.done == true
    end

    test "marks a todo as not done" do
      store = new_store()
      {:ok, todo} = TodoStore.create(store, "Task", [])
      TodoStore.update(store, todo.id, %{"done" => true})
      assert {:ok, updated} = TodoStore.update(store, todo.id, %{"done" => false})
      assert updated.done == false
    end

    test "updates tags" do
      store = new_store()
      {:ok, todo} = TodoStore.create(store, "Task", ["old"])
      assert {:ok, updated} = TodoStore.update(store, todo.id, %{"tags" => ["new"]})
      assert updated.tags == ["new"]
    end

    test "accepts atom keys in the changes map" do
      store = new_store()
      {:ok, todo} = TodoStore.create(store, "Task", [])
      assert {:ok, updated} = TodoStore.update(store, todo.id, %{done: true})
      assert updated.done == true
    end

    test "unspecified fields are not changed" do
      store = new_store()
      {:ok, todo} = TodoStore.create(store, "Task", ["tag1"])
      assert {:ok, updated} = TodoStore.update(store, todo.id, %{"done" => true})
      assert updated.content == "Task"
      assert updated.tags == ["tag1"]
    end

    test "returns not_found for unknown id" do
      store = new_store()
      assert {:error, :not_found} = TodoStore.update(store, "nonexistent", %{"done" => true})
    end

    test "persists the update to future list calls" do
      store = new_store()
      {:ok, todo} = TodoStore.create(store, "Task", [])
      TodoStore.update(store, todo.id, %{"done" => true})
      {:ok, [listed]} = TodoStore.list(store)
      assert listed.done == true
    end
  end

  describe "delete/2" do
    test "removes the todo from the store" do
      store = new_store()
      {:ok, todo} = TodoStore.create(store, "Task", [])
      assert :ok = TodoStore.delete(store, todo.id)
      assert {:ok, []} = TodoStore.list(store)
    end

    test "only removes the targeted todo" do
      store = new_store()
      {:ok, a} = TodoStore.create(store, "Keep", [])
      {:ok, b} = TodoStore.create(store, "Remove", [])
      assert :ok = TodoStore.delete(store, b.id)
      assert {:ok, [remaining]} = TodoStore.list(store)
      assert remaining.id == a.id
    end

    test "returns not_found for unknown id" do
      store = new_store()
      assert {:error, :not_found} = TodoStore.delete(store, "nonexistent")
    end
  end
end
