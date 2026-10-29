defmodule Overalls.ADRValidator do
  @moduledoc """
  Structural validation for the repository's deliberately small ADR format.

  Does not fetch external links, check Markdown anchors, or judge whether linked
  implementation evidence actually satisfies a decision.
  """

  @metadata [
    "ID",
    "Date",
    "Status",
    "Implementation",
    "Components",
    "Supersedes",
    "Superseded by"
  ]
  @sections [
    "Context",
    "Decision",
    "Alternatives",
    "Consequences",
    "Invariants and verification",
    "Implementation evidence",
    "Open questions",
    "Related decisions"
  ]
  @statuses ~w(proposed accepted rejected superseded)
  @implementations ~w(planned partial implemented)
  @id_pattern ~r/^ADR-\d{4}$/

  @type adr_record :: %{
          path: String.t(),
          text: String.t(),
          metadata: %{String.t() => String.t()},
          sections: %{String.t() => String.t()}
        }
  @type result :: {:ok, non_neg_integer()} | {:error, [String.t()]}

  # @cc [owner:ghuntley,label:verification] structural-adr-evidence
  # check/1 MUST reject broken metadata, index, local evidence links or reciprocal
  # supersession structure; it MUST NOT infer semantic implementation from links
  # or fetch external URLs as part of local validation.
  @spec check(Path.t()) :: result()
  def check(root) do
    root = Path.expand(root)
    architecture = Path.join(root, "docs/architecture")
    decisions = Path.join(architecture, "decisions")
    paths = Path.wildcard(Path.join(decisions, "*.md"))
    adr_paths = Enum.reject(paths, &(Path.basename(&1) in ["README.md", "template.md"]))
    records = Enum.map(adr_paths, &parse/1)
    by_id = Map.new(records, &{&1.metadata["ID"], &1})

    errors =
      required_files(root) ++
        require_true(records != [], "No ADRs found in #{decisions}") ++
        duplicate_errors(Enum.map(records, & &1.metadata["ID"]), "ADR ID") ++
        Enum.flat_map(records, &record_errors(&1, root)) ++
        Enum.flat_map(records, &relationship_errors(&1, by_id)) ++
        cycle_errors(by_id) ++
        index_errors(Path.join(decisions, "README.md"), records) ++
        document_errors(architecture, root, by_id)

    case Enum.uniq(errors) do
      [] -> {:ok, length(records)}
      errors -> {:error, errors}
    end
  end

  defp required_files(root) do
    for relative <- [
          "docs/architecture/README.md",
          "docs/architecture/decisions/README.md",
          "docs/architecture/decisions/template.md",
          "docs/architecture/reviews/README.md"
        ],
        not File.regular?(Path.join(root, relative)),
        do: "Missing required file: #{relative}"
  end

  @spec parse(Path.t()) :: adr_record()
  defp parse(path) do
    text = File.read!(path)
    header = text |> String.split(~r/^## /m, parts: 2) |> hd()
    pairs = Regex.scan(~r/^- ([^:\n]+): (.*)$/m, header, capture: :all_but_first)
    sections = Regex.scan(~r/^## ([^\n]+)\n(.*?)(?=^## |\z)/ms, text, capture: :all_but_first)

    %{
      path: path,
      text: text,
      metadata: Map.new(pairs, fn [key, value] -> {key, String.trim(value)} end),
      sections: Map.new(sections, fn [key, value] -> {key, String.trim(value)} end)
    }
  end

  defp record_errors(record, root) do
    meta = record.metadata
    id = meta["ID"] || ""
    filename = Path.basename(record.path)
    header = record.text |> String.split(~r/^## /m, parts: 2) |> hd()
    keys = Regex.scan(~r/^- ([^:\n]+):/m, header, capture: :all_but_first) |> List.flatten()
    headings = Regex.scan(~r/^## (.+)$/m, record.text, capture: :all_but_first) |> List.flatten()

    errors =
      Enum.flat_map(@metadata, fn key ->
        require_true(present?(meta[key]), "Missing metadata: #{key}")
      end) ++
        duplicate_errors(keys, "metadata key") ++
        Enum.map(keys -- @metadata, &"Unknown metadata key: #{&1}") ++
        require_true(Regex.match?(@id_pattern, id), "Invalid ADR ID: #{id}") ++
        require_true(
          Regex.match?(~r/^\d{4}-[a-z0-9]+(?:-[a-z0-9]+)*\.md$/, filename) and
            String.starts_with?(filename, String.replace_prefix(id, "ADR-", "") <> "-"),
          "Filename must match ID and use NNNN-short-title.md"
        ) ++
        require_true(
          Regex.match?(~r/\A# ADR-\d{4}: \S[^\n]*\n/, record.text) and
            String.starts_with?(record.text, "# #{id}: "),
          "Title must begin with # #{id}: followed by a title"
        ) ++
        require_true(valid_date?(meta["Date"]), "Invalid Date; expected YYYY-MM-DD") ++
        require_true(meta["Status"] in @statuses, "Invalid Status: #{meta["Status"]}") ++
        require_true(
          meta["Implementation"] in @implementations,
          "Invalid Implementation: #{meta["Implementation"]}"
        ) ++
        duplicate_errors(headings, "section") ++
        Enum.flat_map(@sections, fn heading ->
          require_true(present?(record.sections[heading]), "Missing or empty section: #{heading}")
        end) ++
        Enum.flat_map(["Supersedes", "Superseded by"], fn key ->
          value = meta[key] || ""

          require_true(
            value == "none" or
              (present?(value) and Enum.all?(references(value), &Regex.match?(@id_pattern, &1))),
            "#{key} must be none or comma-separated ADR IDs"
          ) ++ duplicate_errors(references(value), "#{key} reference")
        end) ++ evidence_errors(record, root)

    Enum.map(errors, &"#{Path.relative_to(record.path, root)}: #{&1}")
  end

  defp evidence_errors(record, root) do
    if record.metadata["Implementation"] in ~w(partial implemented) do
      evidence = record.sections["Implementation evidence"] || ""
      architecture = Path.join(root, "docs/architecture")

      valid? =
        Enum.any?(links(evidence), fn target ->
          case local_target(target, record.path) do
            nil ->
              false

            path ->
              within?(path, root) and not within?(path, architecture)
          end
        end)

      require_true(
        valid?,
        "Implementation evidence needs a local implementation file outside docs/architecture"
      )
    else
      []
    end
  end

  defp relationship_errors(record, by_id) do
    id = record.metadata["ID"]
    status = record.metadata["Status"]
    supersedes = references(record.metadata["Supersedes"])
    successors = references(record.metadata["Superseded by"])

    errors =
      require_true(
        status == "superseded" == (successors != []),
        "Only superseded records must have Superseded by references"
      ) ++
        require_true(
          supersedes == [] or status in ~w(accepted superseded),
          "Only accepted or superseded records may activate Supersedes"
        ) ++
        Enum.flat_map([{"Supersedes", "Superseded by"}, {"Superseded by", "Supersedes"}], fn
          {key, reciprocal} ->
            Enum.flat_map(references(record.metadata[key]), fn target ->
              case Map.fetch(by_id, target) do
                :error ->
                  ["#{key} references missing #{target}"]

                {:ok, other} ->
                  require_true(id != target, "Cannot supersede itself") ++
                    require_true(
                      id in references(other.metadata[reciprocal]),
                      "#{target} must reciprocate #{key} with #{reciprocal}: #{id}"
                    )
              end
            end)
        end)

    Enum.map(errors, &"#{id}: #{&1}")
  end

  defp cycle_errors(by_id) do
    for id <- Map.keys(by_id), reaches_cycle?(id, by_id, MapSet.new()) do
      "Supersession cycle reachable from #{id}"
    end
  end

  defp reaches_cycle?(id, by_id, visited) do
    cond do
      MapSet.member?(visited, id) ->
        true

      not Map.has_key?(by_id, id) ->
        false

      true ->
        Enum.any?(references(by_id[id].metadata["Supersedes"]), fn target ->
          reaches_cycle?(target, by_id, MapSet.put(visited, id))
        end)
    end
  end

  defp index_errors(path, records) do
    text = if File.regular?(path), do: File.read!(path), else: ""

    rows =
      Regex.scan(
        ~r/^\| \[(ADR-\d{4})\]\(([^)]+)\) \| ([^|]+) \| ([^|]+) \| ([^|]+) \|$/m,
        text,
        capture: :all_but_first
      )

    ids = Enum.map(rows, &hd/1)
    expected = Enum.map(records, & &1.metadata["ID"])

    duplicate_errors(ids, "index ID") ++
      Enum.map(expected -- ids, &"Index missing #{&1}") ++
      Enum.map(ids -- expected, &"Index contains unknown #{&1}") ++
      Enum.flat_map(records, fn record ->
        id = record.metadata["ID"]

        case Enum.find(rows, &(hd(&1) == id)) do
          [^id, target, status, implementation, title] ->
            expected_title =
              record.text
              |> String.split("\n", parts: 2)
              |> hd()
              |> String.replace_prefix("# #{id}: ", "")

            require_true(
              local_target(target, path) == record.path and
                String.trim(status) == record.metadata["Status"] and
                String.trim(implementation) == record.metadata["Implementation"] and
                String.trim(title) == expected_title,
              "Index entry for #{id} does not match its path, statuses or title"
            )

          nil ->
            []
        end
      end)
  end

  defp document_errors(architecture, root, by_id) do
    Enum.flat_map(Path.wildcard(Path.join(architecture, "**/*.md")), fn path ->
      text = File.read!(path)
      label = Path.relative_to(path, root)

      Regex.scan(~r/\bADR-\d{4}\b/, text)
      |> List.flatten()
      |> Enum.uniq()
      |> Enum.reject(&Map.has_key?(by_id, &1))
      |> Enum.map(&"#{label}: Unknown ADR reference: #{&1}")
    end)
  end

  defp links(text),
    do: Regex.scan(~r/\[[^\]\n]*\]\(([^)\n]+)\)/, text, capture: :all_but_first) |> List.flatten()

  defp local_target(target, source) do
    if String.starts_with?(target, "#") or Regex.match?(~r/^[a-zA-Z][a-zA-Z0-9+.-]*:/, target) do
      nil
    else
      target |> String.split("#", parts: 2) |> hd() |> Path.expand(Path.dirname(source))
    end
  end

  defp references(value) when value in [nil, "", "none"], do: []
  defp references(value), do: String.split(value, ",") |> Enum.map(&String.trim/1)

  defp within?(path, directory),
    do: path == directory or String.starts_with?(path, directory <> "/")

  defp present?(value), do: is_binary(value) and String.trim(value) != ""

  defp valid_date?(date) when is_binary(date),
    do: Regex.match?(~r/^\d{4}-\d{2}-\d{2}$/, date) and match?({:ok, _}, Date.from_iso8601(date))

  defp valid_date?(_), do: false
  defp require_true(true, _message), do: []
  defp require_true(false, message), do: [message]

  defp duplicate_errors(values, label) do
    values
    |> Enum.frequencies()
    |> Enum.filter(fn {_value, count} -> count > 1 end)
    |> Enum.map(fn {value, _count} -> "Duplicate #{label}: #{value}" end)
  end
end
