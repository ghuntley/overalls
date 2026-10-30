# Shared by scripts/check_rust_lints.exs and its regression tests (ADR-0265).
defmodule Overalls.RustLints do
  @moduledoc false

  @canonical_dir Path.join(__DIR__, "rust")
  @member_lints "[lints]\nworkspace = true\n"
  @lint_attribute ~r/#!?\[\s*(allow|expect)\s*\(/

  @type finding :: {Path.t(), pos_integer() | nil, String.t()}
  @type adoption :: :adopted | :pending

  @spec canonical_lints() :: String.t()
  def canonical_lints, do: File.read!(Path.join(@canonical_dir, "lints.toml"))

  @spec canonical_clippy() :: String.t()
  def canonical_clippy, do: File.read!(Path.join(@canonical_dir, "clippy.toml"))

  @doc "The canonical block rewritten for a Cargo workspace root."
  @spec workspace_lints(String.t()) :: String.t()
  def workspace_lints(lints), do: String.replace(lints, ~r/^\[lints\./m, "[workspace.lints.")

  # @cc [owner:ghuntley,label:governance;verification] rust-lint-policy-no-drift
  # A Cargo manifest that declares any lint table MUST carry the canonical
  # ADR-0265 block verbatim (as `[workspace.lints.*]` for a workspace root, or
  # `[lints] workspace = true` for a member) with a byte-identical clippy.toml
  # beside every non-member manifest. Strict mode MUST also refuse manifests
  # that have not adopted the policy, so adoption can only ratchet forward.
  @spec manifest_findings(Path.t(), String.t(), :member | :root | :standalone, %{
          optional(:clippy) => String.t() | nil
        }) :: {adoption(), [finding()]}
  def manifest_findings(path, text, kind, siblings) do
    lints = canonical_lints()

    {adopted?, ok?} =
      case kind do
        :member ->
          {String.contains?(text, "[lints]"), String.contains?(text, @member_lints)}

        :root ->
          {String.contains?(text, "[workspace.lints"),
           String.contains?(text, workspace_lints(lints))}

        :standalone ->
          {String.contains?(text, "[lints"), String.contains?(text, lints)}
      end

    cond do
      not adopted? ->
        {:pending, []}

      not ok? ->
        {:adopted, [{path, nil, "lint table differs from scripts/rust/lints.toml"}]}

      kind != :member and Map.get(siblings, :clippy) != canonical_clippy() ->
        {:adopted, [{path, nil, "clippy.toml missing or differs from scripts/rust/clippy.toml"}]}

      true ->
        {:adopted, []}
    end
  end

  # @cc [owner:ghuntley,label:governance] rust-lint-exception-has-reason
  # Every `allow`/`expect` lint attribute in an adopted crate MUST carry a
  # `reason = "..."`, so each exception records why it is sound.
  @spec attribute_findings(Path.t(), String.t()) :: [finding()]
  def attribute_findings(path, source) do
    @lint_attribute
    |> Regex.scan(source, return: :index)
    |> Enum.map(fn [{start, _} | _] -> {start, attribute_text(source, start)} end)
    |> Enum.reject(fn {_, text} -> Regex.match?(~r/\breason\s*=/, text) end)
    |> Enum.map(fn {start, _} ->
      {path, line_of(source, start), "lint exception without reason"}
    end)
  end

  @spec attribute_text(String.t(), non_neg_integer()) :: String.t()
  defp attribute_text(source, start) do
    rest = binary_part(source, start, byte_size(source) - start)
    take_balanced(rest, 0, 0)
  end

  @spec take_balanced(String.t(), non_neg_integer(), integer()) :: String.t()
  defp take_balanced(rest, index, _depth) when index >= byte_size(rest), do: rest

  defp take_balanced(rest, index, depth) do
    case :binary.at(rest, index) do
      ?[ -> take_balanced(rest, index + 1, depth + 1)
      ?] when depth == 1 -> binary_part(rest, 0, index + 1)
      ?] -> take_balanced(rest, index + 1, depth - 1)
      _ -> take_balanced(rest, index + 1, depth)
    end
  end

  @spec line_of(String.t(), non_neg_integer()) :: pos_integer()
  defp line_of(source, offset),
    do: source |> binary_part(0, offset) |> :binary.matches("\n") |> length() |> Kernel.+(1)

  @spec manifests([Path.t()]) :: [Path.t()]
  def manifests(paths),
    do: Enum.filter(paths, &(Path.basename(&1) == "Cargo.toml" and not vendored?(&1)))

  @spec vendored?(Path.t()) :: boolean()
  def vendored?(path), do: path |> Path.split() |> Enum.member?("vendor")

  @spec kind(Path.t(), String.t(), [Path.t()]) :: :member | :root | :standalone
  def kind(path, text, workspace_roots) do
    dir = Path.dirname(path)

    cond do
      String.contains?(text, "[workspace]") -> :root
      Enum.any?(workspace_roots, &(&1 != dir and within?(dir, &1))) -> :member
      true -> :standalone
    end
  end

  @spec check([Path.t()], boolean()) :: {[Path.t()], [finding()]}
  def check(paths, strict?) do
    manifests = manifests(paths)
    texts = Map.new(manifests, &{&1, File.read!(&1)})

    roots =
      for {path, text} <- texts, String.contains?(text, "[workspace]"), do: Path.dirname(path)

    results =
      Enum.map(manifests, fn path ->
        text = Map.fetch!(texts, path)
        kind = kind(path, text, roots)
        clippy = Path.join(Path.dirname(path), "clippy.toml")
        siblings = %{clippy: if(File.exists?(clippy), do: File.read!(clippy))}
        {adoption, findings} = manifest_findings(path, text, kind, siblings)
        {path, adoption, findings}
      end)

    adoption = Map.new(results, fn {path, adoption, _} -> {Path.dirname(path), adoption} end)
    pending = for {path, :pending, _} <- results, do: path

    attribute_findings =
      paths
      |> Enum.filter(&(Path.extname(&1) == ".rs" and not vendored?(&1)))
      |> Enum.filter(&(owning_adoption(&1, adoption) == :adopted))
      |> Enum.flat_map(&attribute_findings(&1, File.read!(&1)))

    strict_findings =
      if strict?,
        do: Enum.map(pending, &{&1, nil, "crate has not adopted ADR-0265 lints"}),
        else: []

    {pending, Enum.flat_map(results, &elem(&1, 2)) ++ attribute_findings ++ strict_findings}
  end

  @doc """
  The adoption of the crate that owns `rs`: the nearest enclosing manifest, so
  a workspace member that has not opted in stays pending under an adopted root.
  """
  @spec owning_adoption(Path.t(), %{Path.t() => adoption()}) :: adoption() | nil
  def owning_adoption(rs, adoption) do
    adoption
    |> Enum.filter(fn {dir, _} -> within?(rs, dir) end)
    |> Enum.max_by(fn {dir, _} -> byte_size(dir) end, fn -> {nil, nil} end)
    |> elem(1)
  end

  @doc """
  Whether repository-relative `path` lies below directory `dir`. The root
  Cargo workspace (ADR-0273) sits at `.`, which encloses every path.
  """
  @spec within?(Path.t(), Path.t()) :: boolean()
  def within?(_path, "."), do: true
  def within?(path, dir), do: String.starts_with?(path, dir <> "/")

  @spec tracked() :: [Path.t()]
  def tracked do
    {output, 0} = System.cmd("git", ["ls-files", "-z"])
    String.split(output, <<0>>, trim: true)
  end
end
