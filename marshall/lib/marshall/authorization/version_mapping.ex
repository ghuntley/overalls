defmodule Marshall.Authorization.VersionMapping do
  @moduledoc """
  The `cedar` mapping mixed into every paper-trail version resource: history is
  read and recorded only by the compute coordinator, and the generated update
  action is never callable. Paper-trail writes versions inside the audited
  action without re-authorizing, because no Marshall domain sets `authorize :always`.
  """

  defmacro __using__(_opts) do
    quote do
      cedar do
        internal([:read, :create])
        refused([:update])
      end
    end
  end
end
