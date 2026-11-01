defmodule Lilly.Host.RootOwner do
  @moduledoc """
  Decides whether a file's owner is the host's root user, for the system-file
  checks that require root ownership on its own (`/etc/machine-id`, the VMM
  executables and their ancestor directories).

  Production builds accept exactly uid 0. Test builds compiled with
  `config :lilly, Lilly.Host.RootOwner, unmapped_root: true` also accept the
  kernel overflow uid, but only while the BEAM runs in a user namespace whose
  uid map has no uid 0. No file can appear root-owned there: the kernel
  reports every owner outside the map, host root included, as the overflow
  uid. The Buck2 test sandbox (bubblewrap) maps only the caller's uid, so
  root-owned store paths and the bound `/etc/machine-id` appear owned by
  65534. Wherever uid 0 is mapped (the host, devenv, a GitHub runner) the
  test build behaves exactly like production.
  """

  @unmapped_root Application.compile_env(:lilly, [__MODULE__, :unmapped_root], false)

  # @cc [owner:ghuntley,label:security] root-owner-exact-in-production
  # root?/1 MUST accept a stat owned by uid 0 and, unless the module was
  # compiled with the test-only `unmapped_root` setting, MUST reject every
  # other uid. With that setting it MAY additionally accept the kernel
  # overflow uid, and only when /proc/self/uid_map has no range containing
  # inside uid 0; it MUST NOT accept the BEAM's own uid or any other mapped uid. The
  # setting is read at compile time, so a release's runtime configuration
  # cannot enable it.
  @spec root?(File.Stat.t()) :: boolean()
  def root?(%File.Stat{uid: 0}), do: true

  if @unmapped_root do
    def root?(%File.Stat{uid: uid}) when is_integer(uid), do: uid == unmapped_root_uid()
  end

  def root?(_), do: false

  @doc false
  @spec unmapped_root_enabled?() :: boolean()
  def unmapped_root_enabled?, do: @unmapped_root

  if @unmapped_root do
    # The overflow uid when this user namespace maps no uid 0, else -1 (no
    # stat uid). Computed once; a process cannot change its namespace's uid
    # map after it has been written.
    @spec unmapped_root_uid() :: integer()
    defp unmapped_root_uid do
      case :persistent_term.get({__MODULE__, :unmapped_root_uid}, nil) do
        nil ->
          uid = read_unmapped_root_uid()
          :persistent_term.put({__MODULE__, :unmapped_root_uid}, uid)
          uid

        uid ->
          uid
      end
    end

    @spec read_unmapped_root_uid() :: integer()
    defp read_unmapped_root_uid do
      with {:ok, map} <- File.read("/proc/self/uid_map"),
           {:ok, ranges} <- parse_uid_map(map),
           false <-
             Enum.any?(ranges, fn {inside, _outside, count} -> inside == 0 and count > 0 end),
           {:ok, overflow} <- File.read("/proc/sys/kernel/overflowuid"),
           {uid, ""} when uid > 0 <- Integer.parse(String.trim(overflow)) do
        uid
      else
        _ -> -1
      end
    end
  end

  @doc false
  @spec parse_uid_map(String.t()) ::
          {:ok, [{non_neg_integer(), non_neg_integer(), non_neg_integer()}]} | :error
  def parse_uid_map(text) when is_binary(text) do
    text
    |> String.split("\n", trim: true)
    |> Enum.reduce_while({:ok, []}, fn line, {:ok, acc} ->
      case line |> String.split() |> Enum.map(&Integer.parse/1) do
        [{inside, ""}, {outside, ""}, {count, ""}]
        when inside >= 0 and outside >= 0 and count >= 0 ->
          {:cont, {:ok, [{inside, outside, count} | acc]}}

        _ ->
          {:halt, :error}
      end
    end)
  end
end
