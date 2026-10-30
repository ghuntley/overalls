# SPDX-FileCopyrightText: 2026 Zach Daniel
#
# SPDX-License-Identifier: MIT

defmodule AshScim.Decoder do
  @moduledoc """
  Decodes inbound SCIM 2.0 JSON payloads into Ash action input.

  The decoded result has two parts:

    * `:attrs` — a flat `%{atom => value}` map suitable for
      `Ash.Changeset.for_create/3` or `for_update/3`.
    * `:relationships` — a `%{atom => [%{atom => value}]}` map of
      relationship-management input for relationship-backed multivalued
      attributes (full-replace semantics for top-level body inclusion).

  Per RFC 7644 §3.1, unknown attributes are silently dropped. Emit-only
  static-value mappings are skipped on the way in.

  Multivalueds with `mirror_primary_to:` set additionally write the primary
  entry's `value` to the named scalar attribute on the parent.
  """

  alias AshScim.Dsl.{Complex, Extension, Map, Multivalued}

  @type decoded :: %{
          attrs: %{atom() => term()},
          relationships: %{atom() => [%{atom() => term()}]}
        }

  @doc """
  Decode a SCIM resource JSON map into structured Ash action input.
  """
  @spec decode(module(), %{String.t() => term()}) :: decoded()
  def decode(resource, %{} = body) do
    resource
    |> AshScim.Info.scim_mappings()
    |> Enum.reduce(%{attrs: %{}, relationships: %{}}, fn mapping, acc ->
      apply_mapping(mapping, body, acc)
    end)
  end

  defp apply_mapping(%Map{} = m, body, acc) do
    case decode_simple_map(m, body) do
      addition when addition == %{} -> acc
      addition -> %{acc | attrs: Elixir.Map.merge(acc.attrs, addition)}
    end
  end

  defp apply_mapping(%Extension{urn: urn} = ext, body, acc) do
    case Elixir.Map.fetch(body, urn) do
      {:ok, %{} = inner} ->
        (ext.maps ++ ext.complexes ++ ext.multivalueds)
        |> Enum.reduce(acc, fn mapping, acc -> apply_mapping(mapping, inner, acc) end)

      _ ->
        acc
    end
  end

  defp apply_mapping(%Complex{name: name, maps: maps}, body, acc) do
    case Elixir.Map.fetch(body, to_string(name)) do
      {:ok, %{} = inner} ->
        addition =
          Enum.reduce(maps, %{}, fn sub_map, sub_acc ->
            sub_map |> decode_simple_map(inner) |> merge_attrs(sub_acc)
          end)

        %{acc | attrs: Elixir.Map.merge(acc.attrs, addition)}

      _ ->
        acc
    end
  end

  defp apply_mapping(%Multivalued{relationship: rel, maps: maps} = mv, body, acc) do
    case Elixir.Map.fetch(body, to_string(mv.name)) do
      {:ok, list} when is_list(list) ->
        objects = Enum.filter(list, &is_map/1)

        rel_inputs =
          objects
          |> Enum.map(&decode_relationship_element(&1, maps))
          |> Enum.reject(&(&1 == %{}))

        acc
        |> maybe_put_relationships(rel, list, rel_inputs)
        |> maybe_mirror_primary(mv, objects)

      _ ->
        acc
    end
  end

  defp decode_simple_map(%Map{attribute: nil}, _body), do: %{}

  defp decode_simple_map(%Map{name: name, attribute: attr}, body) do
    case Elixir.Map.fetch(body, to_string(name)) do
      {:ok, value} -> %{attr => value}
      :error -> %{}
    end
  end

  defp decode_relationship_element(element, maps) do
    Enum.reduce(maps, %{}, fn sub_map, acc ->
      sub_map |> decode_simple_map(element) |> merge_attrs(acc)
    end)
  end

  defp merge_attrs(addition, acc) when addition == %{}, do: acc
  defp merge_attrs(addition, acc), do: Elixir.Map.merge(acc, addition)

  # Pick the primary entry deterministically: an explicit `primary: true`
  # wins; otherwise sort by SCIM `value` (lexicographically) and take the
  # first. Sorting ensures the choice doesn't drift if entries are
  # re-ordered by the IdP between requests.
  @doc false
  @spec pick_primary([%{String.t() => term()}]) :: %{String.t() => term()} | nil
  def pick_primary([]), do: nil

  def pick_primary(objects) do
    case Enum.find(objects, &(Elixir.Map.get(&1, "primary") == true)) do
      nil -> objects |> Enum.sort_by(&sort_key/1) |> List.first()
      element -> element
    end
  end

  defp sort_key(map) do
    case Elixir.Map.get(map, "value") do
      v when is_binary(v) -> v
      v -> inspect(v)
    end
  end

  # Marshall-local change: an explicitly empty list (`"members": []`) is a
  # full replacement with no members, so a PUT clears the relationship. A
  # non-empty list whose elements all fail to decode is still ignored rather
  # than treated as a request to remove every related row.
  defp maybe_put_relationships(acc, nil, _list, _rel_inputs), do: acc

  defp maybe_put_relationships(acc, rel, [], []),
    do: %{acc | relationships: Elixir.Map.put(acc.relationships, rel, [])}

  defp maybe_put_relationships(acc, _rel, _list, []), do: acc

  defp maybe_put_relationships(acc, rel, _list, rel_inputs),
    do: %{acc | relationships: Elixir.Map.put(acc.relationships, rel, rel_inputs)}

  defp maybe_mirror_primary(acc, %Multivalued{mirror_primary_to: nil}, _objects), do: acc

  defp maybe_mirror_primary(acc, %Multivalued{mirror_primary_to: mirror_attr}, objects) do
    case pick_primary(objects) do
      nil ->
        acc

      chosen ->
        case Elixir.Map.fetch(chosen, "value") do
          {:ok, value} -> %{acc | attrs: Elixir.Map.put(acc.attrs, mirror_attr, value)}
          :error -> acc
        end
    end
  end
end
