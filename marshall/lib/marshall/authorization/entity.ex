defmodule Marshall.Authorization.Entity do
  @moduledoc """
  A Cedar entity in the `Marshall` namespace. Attribute values are booleans,
  integers, strings, entity references `{type, id}` or lists of those (sets).
  A reference-only entity names a resource without adding it to the entity
  store, for policies that compare identity alone (`resource == principal`).
  """
  alias Marshall.Authorization.Native

  @type reference_term :: Native.reference_term()
  @type value :: Native.value()
  @type t :: %__MODULE__{
          type: String.t(),
          id: String.t(),
          attributes: %{String.t() => value()},
          parents: [reference_term()],
          stored?: boolean()
        }
  @enforce_keys [:type, :id]
  defstruct type: nil, id: nil, attributes: %{}, parents: [], stored?: true

  @spec new(String.t(), String.t(), %{String.t() => value()}) :: t()
  def new(type, id, attributes \\ %{}) when is_binary(type) and is_binary(id),
    do: %__MODULE__{type: type, id: id, attributes: attributes}

  @spec reference_only(String.t(), String.t()) :: t()
  def reference_only(type, id) when is_binary(type) and is_binary(id),
    do: %__MODULE__{type: type, id: id, stored?: false}

  @doc "Entity-store terms for the given entities, without reference-only ones or repeats."
  @spec terms([t()]) :: [Native.entity_term()]
  def terms(entities) do
    entities
    |> Enum.filter(& &1.stored?)
    |> Enum.uniq_by(&reference/1)
    |> Enum.map(&term/1)
  end

  @spec reference(t()) :: reference_term()
  def reference(%__MODULE__{type: type, id: id}), do: {type, id}

  @spec term(t()) :: Native.entity_term()
  def term(%__MODULE__{} = entity),
    do: {entity.type, entity.id, Enum.to_list(entity.attributes), entity.parents}
end
