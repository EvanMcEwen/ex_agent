defmodule ExAgent.Todo do
  @moduledoc "A todo item with content, tags, and completion state."

  @type t :: %__MODULE__{
          id: String.t(),
          content: String.t(),
          tags: [String.t()],
          done: boolean(),
          inserted_at: DateTime.t()
        }

  defstruct [:id, :content, tags: [], done: false, inserted_at: nil]
end
