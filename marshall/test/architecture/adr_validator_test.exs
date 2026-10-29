Code.require_file("../../../scripts/adr_validator.ex", __DIR__)

defmodule Overalls.ADRValidatorTest do
  use ExUnit.Case, async: true
  import Hegel
  import Hegel.Gen

  alias Overalls.ADRValidator

  setup do
    root =
      Path.join(
        System.tmp_dir!(),
        "overalls-adrs-#{System.unique_integer([:positive, :monotonic])}"
      )

    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root}
  end

  test "a planned decision can gain evidence and later retain it after supersession", %{
    root: root
  } do
    first = decision(1)
    fixture(root, [first])
    assert {:ok, 1} = ADRValidator.check(root)

    partial = %{first | implementation: "partial", evidence: "[Code](../../../lib/example.ex)"}
    fixture(root, [partial])
    assert {:ok, 1} = ADRValidator.check(root)

    completed = %{partial | implementation: "implemented"}
    fixture(root, [completed])
    assert {:ok, 1} = ADRValidator.check(root)

    replacement = decision(2, supersedes: [1])
    fixture(root, [%{completed | status: "superseded", successors: [2]}, replacement])
    assert {:ok, 2} = ADRValidator.check(root)
  end

  test "proposed and rejected decisions remain indexed without implying acceptance", %{root: root} do
    fixture(root, [decision(1, status: "proposed"), decision(2, status: "rejected")])
    assert {:ok, 2} = ADRValidator.check(root)
  end

  test "duplicate IDs and mismatched filenames fail", %{root: root} do
    fixture(root, [decision(1)])
    File.cp!(adr_path(root, 1), Path.join(root, "docs/architecture/decisions/0002-copy.md"))
    assert_error(root, "Duplicate ADR ID")
    assert_error(root, "Filename must match ID")
  end

  test "metadata must exist once and use recognized statuses", %{root: root} do
    fixture(root, [decision(1, status: "approved", implementation: "done")])
    edit(adr_path(root, 1), &String.replace(&1, "- Date: 2026-09-15", "- ID: ADR-0001"))
    assert_error(root, "Missing metadata: Date")
    assert_error(root, "Duplicate metadata key")
    assert_error(root, "Invalid Status")
    assert_error(root, "Invalid Implementation")
  end

  test "invalid calendar dates and empty required sections fail", %{root: root} do
    fixture(root, [decision(1)])

    edit(adr_path(root, 1), fn text ->
      text
      |> String.replace("2026-09-15", "2026-02-30")
      |> String.replace("## Context\n\nA concrete constraint.", "## Context\n")
    end)

    assert_error(root, "Invalid Date")
    assert_error(root, "Missing or empty section: Context")
  end

  test "missing architecture files and an empty decision directory fail", %{root: root} do
    fixture(root, [])
    File.rm!(Path.join(root, "docs/architecture/decisions/template.md"))
    assert_error(root, "Missing required file")
    assert_error(root, "No ADRs found")
  end

  test "the index cannot omit, duplicate or invent decisions", %{root: root} do
    fixture(root, [decision(1), decision(2)])

    edit(index_path(root), fn text ->
      text
      |> String.split("\n")
      |> Enum.reject(&String.contains?(&1, "[ADR-0002]"))
      |> Enum.join("\n")
      |> Kernel.<>("\n" <> index_row(decision(1)) <> "\n" <> index_row(decision(3)))
    end)

    assert_error(root, "Index missing ADR-0002")
    assert_error(root, "Duplicate index ID")
    assert_error(root, "Index contains unknown ADR-0003")
  end

  test "the index must match status, implementation, title and path", %{root: root} do
    for {old, new} <- [
          {"| accepted |", "| proposed |"},
          {"| planned |", "| implemented |"},
          {"| Decision 1 |", "| Old title |"},
          {"0001-decision.md", "template.md"}
        ] do
      fixture(root, [decision(1)])
      edit(index_path(root), &String.replace(&1, old, new))
      assert_error(root, "Index entry for ADR-0001 does not match")
    end
  end

  test "ADR references are checked in reviews and overview too", %{root: root} do
    fixture(root, [decision(1)])

    File.write!(
      Path.join(root, "docs/architecture/reviews/review.md"),
      "See ADR-9999."
    )

    assert_error(root, "Unknown ADR reference: ADR-9999")
  end

  test "local links are not required to exist", %{root: root} do
    fixture(root, [decision(1)])

    File.write!(
      Path.join(root, "docs/architecture/reviews/review.md"),
      "See [code](missing.ex) and [moved](../../../lib/removed.ex)."
    )

    assert {:ok, 1} = ADRValidator.check(root)
  end

  test "existing local anchors and external links do not require network access", %{root: root} do
    fixture(root, [decision(1)])

    File.write!(
      Path.join(root, "docs/architecture/README.md"),
      "[Index](decisions/README.md#anything) [Web](https://example.invalid/no-network) [Here](#local)"
    )

    assert {:ok, 1} = ADRValidator.check(root)
  end

  test "partial and implemented need implementation artifacts, not architecture links", %{
    root: root
  } do
    for status <- ~w(partial implemented),
        evidence <- [
          "Planned.",
          "[ADR](0001-decision.md)",
          "[Web](https://example.invalid)"
        ] do
      fixture(root, [decision(1, implementation: status, evidence: evidence)])
      assert_error(root, "Implementation evidence needs a local implementation file")
    end
  end

  test "evidence cannot escape the repository", %{root: root} do
    fixture(root, [decision(1, implementation: "partial", evidence: "[Outside](/etc/hosts)")])
    assert_error(root, "Implementation evidence needs a local implementation file")
  end

  test "supersession must be reciprocal and refer to existing decisions", %{root: root} do
    fixture(root, [decision(1), decision(2, supersedes: [1, 99])])
    assert_error(root, "must reciprocate")
    assert_error(root, "references missing ADR-0099")
  end

  test "superseded status and successors must agree", %{root: root} do
    fixture(root, [decision(1, status: "superseded")])
    assert_error(root, "Only superseded records must have")
    fixture(root, [decision(1, successors: [2]), decision(2, supersedes: [1])])
    assert_error(root, "Only superseded records must have")
  end

  test "a proposed replacement cannot activate supersession", %{root: root} do
    fixture(root, [
      decision(1, status: "superseded", successors: [2]),
      decision(2, status: "proposed", supersedes: [1])
    ])

    assert_error(root, "Only accepted or superseded records may activate")
  end

  test "malformed and duplicate relationship IDs fail", %{root: root} do
    fixture(root, [decision(1, supersedes: [2, 2])])
    assert_error(root, "Duplicate Supersedes reference")
    edit(adr_path(root, 1), &String.replace(&1, "ADR-0002, ADR-0002", "later"))
    assert_error(root, "Supersedes must be none or comma-separated ADR IDs")
  end

  test "self-supersession fails even when reciprocal", %{root: root} do
    fixture(root, [decision(1, status: "superseded", supersedes: [1], successors: [1])])
    assert_error(root, "Cannot supersede itself")
    assert_error(root, "Supersession cycle")
  end

  @tag :hegel
  test "acyclic histories with branches remain valid regardless of decision order", %{
    root: root
  } do
    Hegel.check(
      fn ->
        choices = draw("choices", list_of(integer(0..100), min_length: 2, max_length: 20))

        records =
          choices
          |> Enum.with_index(1)
          |> Enum.map(fn {choice, number} ->
            predecessor = rem(choice, number)
            decision(number, supersedes: if(predecessor == 0, do: [], else: [predecessor]))
          end)
          |> connect_successors()

        fixture(root, Enum.reverse(records))
        assert {:ok, count} = ADRValidator.check(root)
        assert count == length(records)
      end,
      test_cases: 100
    )
  end

  @tag :hegel
  test "closing a valid replacement chain always produces a detected cycle", %{root: root} do
    Hegel.check(
      fn ->
        size = draw("size", integer(2..30))
        chain = Enum.map(1..size, &decision(&1, supersedes: if(&1 == 1, do: [], else: [&1 - 1])))
        fixture(root, connect_successors(chain))
        assert {:ok, ^size} = ADRValidator.check(root)

        cycle = List.update_at(chain, 0, &%{&1 | supersedes: [size]})
        fixture(root, connect_successors(cycle))
        assert_error(root, "Supersession cycle")
      end,
      test_cases: 100
    )
  end

  defp decision(number, attrs \\ []) do
    Map.merge(
      %{
        number: number,
        status: "accepted",
        implementation: "planned",
        evidence: "No implementation yet.",
        supersedes: [],
        successors: []
      },
      Map.new(attrs)
    )
  end

  defp connect_successors(records) do
    Enum.map(records, fn record ->
      successors = for other <- records, record.number in other.supersedes, do: other.number

      %{
        record
        | successors: successors,
          status: if(successors == [], do: "accepted", else: "superseded")
      }
    end)
  end

  defp fixture(root, records) do
    File.rm_rf!(Path.join(root, "docs"))
    File.mkdir_p!(Path.join(root, "docs/architecture/decisions"))
    File.mkdir_p!(Path.join(root, "docs/architecture/reviews"))
    File.mkdir_p!(Path.join(root, "lib"))
    File.write!(Path.join(root, "lib/example.ex"), "# Implementation fixture\n")

    for relative <- ["README.md", "decisions/template.md", "reviews/README.md"] do
      File.write!(Path.join(root, "docs/architecture/#{relative}"), "# Documentation\n")
    end

    File.write!(
      index_path(root),
      "# Decisions\n\n" <> Enum.map_join(records, "\n", &index_row/1) <> "\n"
    )

    for record <- records do
      File.write!(adr_path(root, record.number), """
      # #{id(record.number)}: Decision #{record.number}

      - ID: #{id(record.number)}
      - Date: 2026-09-15
      - Status: #{record.status}
      - Implementation: #{record.implementation}
      - Components: tests
      - Supersedes: #{references(record.supersedes)}
      - Superseded by: #{references(record.successors)}

      ## Context

      A concrete constraint.

      ## Decision

      A chosen behavior.

      ## Alternatives

      Another behavior.

      ## Consequences

      A cost.

      ## Invariants and verification

      Test an observable property.

      ## Implementation evidence

      #{record.evidence}

      ## Open questions

      None.

      ## Related decisions

      None.
      """)
    end
  end

  defp index_row(record),
    do:
      "| [#{id(record.number)}](#{filename(record.number)}) | #{record.status} | #{record.implementation} | Decision #{record.number} |"

  defp id(number), do: "ADR-" <> String.pad_leading(Integer.to_string(number), 4, "0")
  defp filename(number), do: String.replace_prefix(id(number), "ADR-", "") <> "-decision.md"

  defp adr_path(root, number),
    do: Path.join(root, "docs/architecture/decisions/#{filename(number)}")

  defp index_path(root), do: Path.join(root, "docs/architecture/decisions/README.md")
  defp references([]), do: "none"
  defp references(numbers), do: Enum.map_join(numbers, ", ", &id/1)
  defp edit(path, fun), do: File.write!(path, fun.(File.read!(path)))

  defp assert_error(root, message) do
    assert {:error, errors} = ADRValidator.check(root)
    assert Enum.any?(errors, &String.contains?(&1, message)), inspect(errors)
  end
end
