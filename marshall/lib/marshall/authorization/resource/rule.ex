defmodule Marshall.Authorization.Resource.Rule do
  @moduledoc "One `cedar` mapping entry of a resource."
  @type kind :: :control_plane | :internal | :service | :record | :refused
  @type service :: :ash_authentication | :scim
  @type t :: %__MODULE__{
          kind: kind(),
          cedar_action: String.t() | nil,
          service: service() | nil,
          entity_type: String.t() | nil,
          actions: [atom()],
          __spark_metadata__: term()
        }
  defstruct [:kind, :cedar_action, :service, :entity_type, :__spark_metadata__, actions: []]
end
