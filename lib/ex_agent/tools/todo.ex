defmodule ExAgent.Tools.Todo do
  @moduledoc """
  `ReqLLM.Tool` definitions for todo CRUD operations.

  Each tool closes over a `%ExAgent.TodoStore{}` so mutations from LLM tool
  calls are reflected immediately in the same store process.

  ## Usage

      {:ok, store} = ExAgent.TodoStore.new(ExAgent.TodoStore.InMemory)

      agent = %ExAgent.Agent{
        model: "anthropic:claude-sonnet-4-20250514",
        tools: ExAgent.Tools.Todo.tools(store)
      }

  ## Tools

    * `todo_create` — create a new todo with content and optional tags
    * `todo_list`   — list all todos, optionally filtered by tag
    * `todo_update` — update content, tags, or done status by id
    * `todo_delete` — delete a todo by id
  """

  alias ExAgent.TodoStore

  @doc """
  Returns the four CRUD tools bound to the given `store`.
  """
  @spec tools(TodoStore.t()) :: [ReqLLM.Tool.t()]
  def tools(%TodoStore{} = store) do
    [
      create_tool(store),
      list_tool(store),
      update_tool(store),
      delete_tool(store)
    ]
  end

  defp create_tool(store) do
    ReqLLM.Tool.new!(
      name: "todo_create",
      description: "Create a new todo item. Returns the created todo including its ID.",
      parameter_schema: %{
        "type" => "object",
        "properties" => %{
          "content" => %{
            "type" => "string",
            "description" => "The text of the todo item"
          },
          "tags" => %{
            "type" => "array",
            "items" => %{"type" => "string"},
            "description" => "Optional tags that categorize the todo into named lists"
          }
        },
        "required" => ["content"]
      },
      callback: fn args ->
        content = args["content"]
        tags = args["tags"] || []
        TodoStore.create(store, content, tags)
      end
    )
  end

  defp list_tool(store) do
    ReqLLM.Tool.new!(
      name: "todo_list",
      description:
        "List todo items. Omit `tag` to return all todos, or provide a tag to filter to a specific list.",
      parameter_schema: %{
        "type" => "object",
        "properties" => %{
          "tag" => %{
            "type" => "string",
            "description" => "Return only todos that include this tag"
          }
        }
      },
      callback: fn args ->
        TodoStore.list(store, args["tag"])
      end
    )
  end

  defp update_tool(store) do
    ReqLLM.Tool.new!(
      name: "todo_update",
      description:
        "Update a todo item by ID. Provide any combination of `content`, `tags`, and `done` to change.",
      parameter_schema: %{
        "type" => "object",
        "properties" => %{
          "id" => %{
            "type" => "string",
            "description" => "The ID of the todo to update"
          },
          "content" => %{
            "type" => "string",
            "description" => "New text for the todo"
          },
          "tags" => %{
            "type" => "array",
            "items" => %{"type" => "string"},
            "description" => "Replacement tag list for the todo"
          },
          "done" => %{
            "type" => "boolean",
            "description" => "Whether the todo is completed"
          }
        },
        "required" => ["id"]
      },
      callback: fn args ->
        id = args["id"]
        changes = Map.take(args, ["content", "tags", "done"])
        TodoStore.update(store, id, changes)
      end
    )
  end

  defp delete_tool(store) do
    ReqLLM.Tool.new!(
      name: "todo_delete",
      description: "Delete a todo item by ID.",
      parameter_schema: %{
        "type" => "object",
        "properties" => %{
          "id" => %{
            "type" => "string",
            "description" => "The ID of the todo to delete"
          }
        },
        "required" => ["id"]
      },
      callback: fn args ->
        TodoStore.delete(store, args["id"])
      end
    )
  end
end
