Code.require_file("../../../scripts/rust_lints.ex", __DIR__)

defmodule Overalls.RustLintsTest do
  use ExUnit.Case, async: true
  import Hegel
  import Hegel.Gen
  alias Overalls.RustLints

  @package "[package]\nname = \"x\"\nversion = \"0.1.0\"\nedition = \"2021\"\n\n"

  # @cc [owner:ghuntley,label:verification;governance] rust-lint-reason-oracle
  # Generated sources MUST report exactly the allow/expect attributes that lack
  # a `reason =` argument, whatever their lints, nesting or line placement.
  property "reports exactly the lint exceptions without a reason" do
    attributes =
      draw(
        "attributes",
        list_of(
          tuple({
            member_of([
              "#[allow(",
              "#![allow(",
              "#[expect(",
              "#[ allow (",
              "#[deny(",
              "#![forbid("
            ]),
            member_of([
              "dead_code",
              "clippy::cast_possible_truncation",
              "unsafe_code, dead_code"
            ]),
            boolean()
          }),
          max_length: 12
        )
      )

    lines =
      Enum.map(attributes, fn {open, lint, reason?} ->
        open <> lint <> if(reason?, do: ", reason = \"proved [bounded]\")]", else: ")]")
      end)

    expected =
      attributes
      |> Enum.with_index(1)
      |> Enum.filter(fn {{open, _, reason?}, _} ->
        not reason? and Regex.match?(~r/(allow|expect)/, open)
      end)
      |> Enum.map(fn {_, line} -> {"f.rs", line, "lint exception without reason"} end)

    assert RustLints.attribute_findings("f.rs", Enum.join(lines, "\n")) == expected
  end

  test "a multi-line attribute with a reason on a later line is accepted" do
    source = "#[allow(\n    unsafe_code,\n    reason = \"setns shim\"\n)]\nmod ops;\n"
    assert RustLints.attribute_findings("lib.rs", source) == []
  end

  test "standalone, workspace root and member manifests follow the canonical block" do
    lints = RustLints.canonical_lints()
    clippy = %{clippy: RustLints.canonical_clippy()}

    assert RustLints.manifest_findings("a/Cargo.toml", @package, :standalone, clippy) ==
             {:pending, []}

    assert RustLints.manifest_findings("a/Cargo.toml", @package <> lints, :standalone, clippy) ==
             {:adopted, []}

    drifted =
      String.replace(lints, "pedantic = { level = \"warn\"", "pedantic = { level = \"allow\"")

    assert {:adopted, [{_, nil, "lint table differs" <> _}]} =
             RustLints.manifest_findings("a/Cargo.toml", @package <> drifted, :standalone, clippy)

    assert {:adopted, [{_, nil, "clippy.toml" <> _}]} =
             RustLints.manifest_findings("a/Cargo.toml", @package <> lints, :standalone, %{
               clippy: nil
             })

    root = "[workspace]\nmembers = []\n\n" <> RustLints.workspace_lints(lints)
    assert RustLints.manifest_findings("w/Cargo.toml", root, :root, clippy) == {:adopted, []}

    member = @package <> "[lints]\nworkspace = true\n"
    assert RustLints.manifest_findings("w/m/Cargo.toml", member, :member, %{}) == {:adopted, []}
  end

  test "vendored manifests are out of scope and members are found under workspace roots" do
    assert RustLints.manifests(["lyra/vendor/fs2/Cargo.toml", "lyra/Cargo.toml"]) == [
             "lyra/Cargo.toml"
           ]

    adoption = %{"w" => :adopted, "w/held" => :pending, "w/m" => :adopted}
    assert RustLints.owning_adoption("w/held/src/lib.rs", adoption) == :pending
    assert RustLints.owning_adoption("w/m/src/lib.rs", adoption) == :adopted
    assert RustLints.owning_adoption("w/build.rs", adoption) == :adopted
    assert RustLints.owning_adoption("other/src/lib.rs", adoption) == nil

    assert RustLints.kind("mila/rust/m/Cargo.toml", @package, ["mila/rust"]) == :member
    assert RustLints.kind("mila/rustacean/Cargo.toml", @package, ["mila/rust"]) == :standalone
  end

  test "a workspace root at the repository root encloses every crate (ADR-0273)" do
    root = "[workspace]\nmembers = [\"lyra\"]\n"
    assert RustLints.kind("Cargo.toml", root, ["."]) == :root
    assert RustLints.kind("lyra/Cargo.toml", @package, ["."]) == :member
    assert RustLints.kind("mila/rust/m/Cargo.toml", @package, ["."]) == :member

    adoption = %{"." => :adopted, "lyra" => :adopted, "held" => :pending}
    assert RustLints.owning_adoption("lyra/src/lib.rs", adoption) == :adopted
    assert RustLints.owning_adoption("held/src/lib.rs", adoption) == :pending
    assert RustLints.owning_adoption("scripts/x.rs", adoption) == :adopted
  end
end
