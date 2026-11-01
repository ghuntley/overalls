defmodule Lilly.VM.ExecutorDriveShapeTest do
  use ExUnit.Case, async: true
  import Hegel
  import Hegel.Gen
  alias Lilly.VM.Executor

  @owner 4_242

  @spec stat(keyword()) :: {:ok, File.Stat.t()}
  defp stat(fields),
    do: {:ok, struct(%File.Stat{type: :regular, links: 1, size: 1024, uid: @owner}, fields)}

  # disk-presence-unconfirmed-names-drive-shape: every unclassifiable drive
  # carries exactly one closed reason, and only an exact drive is present.
  test "drive shapes name the first refused property" do
    assert Executor.drive_shape({:error, :enoent}, 1024, @owner) == :absent
    assert Executor.drive_shape({:error, :eacces}, 1024, @owner) == :drive_unreadable
    assert Executor.drive_shape(stat(type: :symlink), 1024, @owner) == :drive_not_regular
    assert Executor.drive_shape(stat(links: 2), 1024, @owner) == :drive_links
    assert Executor.drive_shape(stat(uid: 1), 1024, @owner) == :drive_owner
    assert Executor.drive_shape(stat(size: 512), 1024, @owner) == :drive_smaller
    assert Executor.drive_shape(stat(size: 2048), 1024, @owner) == :drive_larger
    assert Executor.drive_shape(stat([]), 1024, @owner) == :present
    assert Executor.drive_shape(stat(uid: 0), 1024, @owner) == :present
  end

  @tag :hegel
  test "a regular single-link owned drive is present exactly at its expected size" do
    Hegel.check(fn ->
      expected = draw("expected", integer(0..1_099_511_627_776))
      size = draw("size", one_of([constant(expected), integer(0..1_099_511_627_776)]))

      shape = Executor.drive_shape(stat(size: size), expected, @owner)

      cond do
        size == expected -> assert shape == :present
        size < expected -> assert shape == :drive_smaller
        true -> assert shape == :drive_larger
      end
    end)
  end
end
