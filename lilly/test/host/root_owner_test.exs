defmodule Lilly.Host.RootOwnerTest do
  use ExUnit.Case, async: true
  import Hegel
  import Hegel.Gen
  alias Lilly.Host.RootOwner
  @moduletag :tmp_dir

  @spec root_mapped?() :: boolean()
  defp root_mapped? do
    {:ok, ranges} = RootOwner.parse_uid_map(File.read!("/proc/self/uid_map"))
    Enum.any?(ranges, fn {inside, _outside, count} -> inside == 0 and count > 0 end)
  end

  @spec overflow_uid() :: non_neg_integer()
  defp overflow_uid do
    {uid, ""} = "/proc/sys/kernel/overflowuid" |> File.read!() |> String.trim() |> Integer.parse()
    uid
  end

  test "the test build enables the unmapped-root oracle" do
    assert RootOwner.unmapped_root_enabled?()
  end

  test "uid 0 is root and the BEAM's own files never are", %{tmp_dir: root} do
    path = Path.join(root, "own")
    File.write!(path, "")
    {:ok, %File.Stat{uid: owner} = stat} = File.lstat(path)

    assert RootOwner.root?(%File.Stat{stat | uid: 0})
    assert RootOwner.root?(stat) == (owner == 0)
  end

  # root-owner-exact-in-production: besides uid 0, only the overflow uid in
  # a namespace whose uid map has no uid 0 is accepted.
  @tag :hegel
  test "a nonzero uid is root only as the overflow uid where uid 0 is unmapped" do
    overflow = overflow_uid()
    unmapped = not root_mapped?()

    Hegel.check(fn ->
      uid = draw("uid", one_of([constant(overflow), integer(1..4_294_967_294)]))
      assert RootOwner.root?(%File.Stat{uid: uid}) == (unmapped and uid == overflow)
    end)
  end

  test "bubblewrap's nested map (caller only, as 1000) leaves uid 0 unmapped" do
    assert {:ok, [{1000, 0, 1}]} = RootOwner.parse_uid_map("      1000          0          1\n")
  end

  test "uid maps parse into ranges and malformed maps are refused" do
    assert RootOwner.parse_uid_map("         0          0 4294967295\n") ==
             {:ok, [{0, 0, 4_294_967_295}]}

    assert RootOwner.parse_uid_map("      1000       1000          1\n") ==
             {:ok, [{1000, 1000, 1}]}

    assert RootOwner.parse_uid_map("0 0\n") == :error
    assert RootOwner.parse_uid_map("a b c\n") == :error
    assert RootOwner.parse_uid_map("0 -1 1\n") == :error
  end

  # root-owner-exact-in-production: the module as a production build compiles
  # it (no `unmapped_root` configuration) accepts only uid 0, even where uid 0
  # is unmapped.
  test "a production compile accepts only uid 0" do
    probe = Lilly.Host.RootOwnerProductionProbe
    source = File.read!(Path.expand("../../lib/lilly/host/root_owner.ex", __DIR__))

    quoted =
      source
      |> Code.string_to_quoted!()
      |> Macro.prewalk(fn
        {:__aliases__, meta, [:Lilly, :Host, :RootOwner]} ->
          {:__aliases__, meta, [:Lilly, :Host, :RootOwnerProductionProbe]}

        node ->
          node
      end)

    assert Application.get_env(:lilly, probe) == nil

    [{^probe, _}] = Code.compile_quoted(quoted)
    refute apply(probe, :unmapped_root_enabled?, [])

    # Simulate the bubblewrap namespace: the overflow uid is known and uid 0
    # is unmapped. The production build still refuses it.
    :persistent_term.put({probe, :unmapped_root_uid}, overflow_uid())

    try do
      assert apply(probe, :root?, [%File.Stat{uid: 0}])
      refute apply(probe, :root?, [%File.Stat{uid: overflow_uid()}])
      refute apply(probe, :root?, [%File.Stat{uid: 1000}])
    after
      :persistent_term.erase({probe, :unmapped_root_uid})
      :code.purge(probe)
      :code.delete(probe)
    end
  end

  test "no production configuration enables the unmapped-root oracle" do
    config = Config.Reader.read!(Path.expand("../../config/config.exs", __DIR__), env: :prod)
    assert get_in(config, [:lilly, RootOwner]) == nil

    runtime = Path.expand("../../config/runtime.exs", __DIR__)

    if File.exists?(runtime) do
      refute File.read!(runtime) =~ "RootOwner"
    end
  end

  test "a stat without a uid is never root" do
    refute RootOwner.root?(%File.Stat{})
  end
end
