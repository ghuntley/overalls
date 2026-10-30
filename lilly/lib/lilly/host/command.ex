defmodule Lilly.Host.Command do
  @moduledoc "Bounded invocations of fixed host utilities. Arguments are never interpreted by a shell."
  require Lilly.Events

  @executables %{
    image_copy: "lilly-image-copy",
    image_identity: "lilly-image-copy",
    mkfifo: "mkfifo",
    ssh_keygen: "ssh-keygen",
    kvm_probe: "lilly-kvm-probe",
    resume_token: "lilly-resume-token",
    flow_label: "lilly-flow-label",
    zfs_namespace_unmount: "lilly-zfs-namespace-unmount",
    zfs_list: "zfs",
    zfs_get: "zfs",
    zfs_snapshot: "zfs",
    zfs_create: "zfs",
    zfs_destroy: "zfs",
    zfs_mount: "zfs",
    zfs_set: "zfs",
    zfs_rename: "zfs",
    zfs_unmount: "zfs",
    zfs_receive_abort: "zfs",
    truncate: "truncate",
    zpool_status: "zpool",
    zpool_get: "zpool",
    zpool_iostat: "zpool",
    mv: "mv",
    rm: "rm",
    stat: "stat",
    findmnt: "findmnt",
    realpath: "realpath",
    sync: "sync",
    ip: "ip",
    nft: "nft",
    sysctl: "sysctl",
    cp: "cp",
    mount: "mount",
    umount: "umount",
    chown: "chown",
    systemctl: "systemctl",
    chmod: "chmod"
  }
  @type name ::
          :image_copy
          | :image_identity
          | :mkfifo
          | :ssh_keygen
          | :kvm_probe
          | :resume_token
          | :flow_label
          | :zfs_namespace_unmount
          | :zfs_list
          | :zfs_get
          | :zfs_snapshot
          | :zfs_create
          | :zfs_destroy
          | :zfs_mount
          | :zfs_set
          | :zfs_rename
          | :zfs_unmount
          | :zfs_receive_abort
          | :truncate
          | :zpool_status
          | :zpool_get
          | :zpool_iostat
          | :mv
          | :rm
          | :stat
          | :findmnt
          | :realpath
          | :sync
          | :ip
          | :nft
          | :sysctl
          | :cp
          | :mount
          | :umount
          | :chown
          | :systemctl
          | :chmod
  @doc false
  # The utility names Command accepts (compared with hostd's table in tests).
  @spec names() :: [name()]
  def names, do: Map.keys(@executables)

  @type error ::
          :utility_unavailable
          | :command_failed
          | :command_timeout
          | :command_output_limit
          | :host_lock_unavailable
          | :host_lock_required

  # @cc [owner:ghuntley,label:security;recovery] mutations-require-lock-owner
  # run/3 MUST reject image_copy, cp, mv, rm, truncate, ZFS create/destroy/mount/unmount/snapshot/set/rename/receive-abort, mount, umount,
  # chown, mkfifo, ssh_keygen, zfs_namespace_unmount and systemctl stop/kill without
  # a current lease. Every utility MUST run in lilly-hostd, named from its
  # closed table and never by path: under the current lease when one is
  # held, so accepted mutations cannot race a successor after caller death,
  # and otherwise as a lease-less read. Lilly spawns no host utility itself.
  # hostd bounds output (64 KiB, or 4 MiB for property trees and mount
  # listings) and time; command_output_limit and command_timeout MUST NOT be
  # taken as proof that an accepted external operation did not occur.

  # @cc [owner:ghuntley,label:recovery] utility-timeout-bounds
  # run/3 MUST accept a timeout of 1000..600000 ms for every utility except image_copy and
  # sync, which accept up to 14400000 ms (a pool's image copy and flush deadline, ADR-0173
  # decision 10); any other timeout MUST be refused before a utility starts.
  @spec run(name(), [String.t()], pos_integer()) :: {:ok, binary()} | {:error, error()}
  def run(name, arguments), do: run(name, arguments, default_timeout(name))

  def run(name, arguments, timeout_ms)
      when is_map_key(@executables, name) and
             (timeout_ms in 1000..600_000 or
                (name in [:image_copy, :sync] and timeout_ms in 1000..14_400_000)) do
    Overalls.Diagnostics.Tracing.with_span("lilly.host.utility", [utility: name], fn ->
      run_native(name, arguments, timeout_ms)
    end)
  end

  # @cc [owner:ghuntley,label:recovery] durable-utility-under-lease
  # run_durable/4 MUST start the utility as a lilly-hostd durable job under the
  # current lease, keyed by the caller's 32-byte key, so it keeps running and
  # keeps the lease if this BEAM's session ends. attach/2 MUST wait at most
  # wait_ms for the result of a job known under the key. Both MUST refuse with
  # :host_lock_required without a current lease.
  @doc "Start one VM unit through hostd's typed launch, under the caller's lease."
  @spec launch_vm(Lilly.Host.Hostd.launch()) :: {:ok, binary()} | {:error, error()}
  def launch_vm(launch) do
    case Lilly.Host.Lock.current() do
      %Lilly.Host.Lease{} = lease -> Lilly.Host.Hostd.launch_vm(lease.session, lease.id, launch)
      nil -> {:error, :host_lock_required}
    end
  end

  @typedoc "The result of starting or attaching to a durable hostd job."
  @type durable_result :: {:ok, binary()} | {:error, error() | :job_running | :job_unknown}

  @spec run_durable(name(), [String.t()], pos_integer(), <<_::256>>) :: durable_result()
  def run_durable(name, arguments, timeout_ms, <<_::256>> = key)
      when is_map_key(@executables, name) and timeout_ms in 1000..14_400_000 do
    case Lilly.Host.Lock.current() do
      %Lilly.Host.Lease{} = lease ->
        Lilly.Host.Hostd.run_durable(
          lease.session,
          lease.id,
          key,
          name,
          prefix(name) ++ arguments,
          timeout_ms,
          65_536
        )

      nil ->
        {:error, :host_lock_required}
    end
  end

  @spec attach(<<_::256>>, 0..120_000) :: durable_result()
  def attach(<<_::256>> = key, wait_ms) do
    case Lilly.Host.Lock.current() do
      %Lilly.Host.Lease{} = lease -> Lilly.Host.Hostd.attach(lease.session, key, wait_ms)
      nil -> {:error, :host_lock_required}
    end
  end

  @spec run_native(name(), [String.t()], pos_integer()) :: {:ok, binary()} | {:error, error()}
  defp run_native(name, arguments, timeout_ms) do
    started = System.monotonic_time(:millisecond)
    lock = Lilly.Host.Lock.current()
    owner = native_owner(lock)
    arguments = prefix(name) ++ arguments
    limit = if name in [:zfs_list, :findmnt], do: 4_194_304, else: 65_536

    if name in [:zfs_create, :zfs_snapshot, :zfs_destroy, :zfs_rename, :zfs_receive_abort] do
      Lilly.Events.emit("lilly.lifecycle_effect_attempted", action: name)
    end

    result =
      case lock do
        nil
        when name in [
               :mkfifo,
               :ssh_keygen,
               :cp,
               :image_copy,
               :mv,
               :rm,
               :truncate,
               :zfs_create,
               :zfs_snapshot,
               :zfs_destroy,
               :zfs_namespace_unmount,
               :zfs_mount,
               :zfs_set,
               :zfs_rename,
               :zfs_unmount,
               :zfs_receive_abort,
               :mount,
               :umount,
               :chown,
               :chmod
             ] ->
          {:error, :host_lock_required}

        nil when name == :systemctl and hd(arguments) in ["stop", "kill"] ->
          {:error, :host_lock_required}

        nil ->
          with {:ok, session} <- Lilly.Host.Hostd.session(),
               do: Lilly.Host.Hostd.run(session, 0, name, arguments, timeout_ms, limit)

        lease ->
          Lilly.Host.Hostd.run(lease.session, lease.id, name, arguments, timeout_ms, limit)
      end

    if name in [:zfs_create, :zfs_snapshot, :zfs_destroy, :zfs_rename, :zfs_receive_abort] do
      outcome =
        case result do
          {:ok, _} -> :utility_succeeded
          {:error, reason} -> reason
        end

      Lilly.Events.emit("lilly.lifecycle_effect_returned", action: name, reason: outcome)
    end

    report_uncertainty(result, name, started, owner)
  end

  # @cc [owner:ghuntley,label:security;observability] utility-uncertainty-private
  # Bounds/ownership failures MUST log only the fixed utility and reason enums,
  # elapsed milliseconds and an optional numeric lease id. Never log
  # arguments, executable paths or utility output. Logging MUST preserve the
  # result and MUST NOT claim that a timed-out mutation did not occur.
  defp report_uncertainty({:error, reason} = result, name, started, owner)
       when reason in [:command_timeout, :command_output_limit, :host_lock_unavailable] do
    duration = max(0, System.monotonic_time(:millisecond) - started)

    if owner do
      Lilly.Events.emit("lilly.utility_unconfirmed",
        utility: name,
        reason: reason,
        duration_ms: duration,
        lease_id: owner
      )
    else
      Lilly.Events.emit("lilly.utility_unconfirmed",
        utility: name,
        reason: reason,
        duration_ms: duration
      )
    end

    result
  end

  defp report_uncertainty(result, _, _, _), do: result

  defp native_owner(nil), do: nil
  defp native_owner(%Lilly.Host.Lease{id: id}), do: id

  # @cc [owner:ghuntley,label:recovery;storage] zfs-mutation-default-bound
  # ZFS mutations MUST default to a bound that survives a loaded host. A
  # create, set or rename can unmount and remount; cutting it off at the
  # short utility default left an owned dataset unmounted (2026-10-09 standby
  # claim, 2026-10-10 template create) and accounting withheld the pool. Other
  # utilities keep the short default; explicit bounds still apply.
  @zfs_mutations [
    :zfs_create,
    :zfs_set,
    :zfs_mount,
    :zfs_unmount,
    :zfs_rename,
    :zfs_destroy,
    :zfs_snapshot,
    :zfs_receive_abort
  ]
  @doc false
  @spec default_timeout(name()) :: pos_integer()
  def default_timeout(name) when name in @zfs_mutations, do: 120_000
  def default_timeout(_name), do: 3000

  defp prefix(:zfs_list), do: ["list"]
  defp prefix(:zfs_get), do: ["get"]
  defp prefix(:zfs_snapshot), do: ["snapshot"]
  defp prefix(:image_identity), do: ["identity"]
  defp prefix(:zfs_create), do: ["create"]
  defp prefix(:zfs_mount), do: ["mount"]
  defp prefix(:zfs_set), do: ["set"]
  defp prefix(:zfs_rename), do: ["rename"]
  defp prefix(:zfs_unmount), do: ["unmount"]
  defp prefix(:zfs_receive_abort), do: ["receive", "-A"]
  defp prefix(:zfs_destroy), do: ["destroy"]
  defp prefix(:zpool_status), do: ["status"]
  defp prefix(:zpool_get), do: ["get"]
  defp prefix(:zpool_iostat), do: ["iostat"]
  defp prefix(_), do: []

  @spec in_namespace(String.t(), name(), [String.t()]) :: {:ok, binary()} | {:error, error()}
  def in_namespace(namespace, name, arguments) when is_map_key(@executables, name) do
    case System.find_executable(Map.fetch!(@executables, name)) do
      nil ->
        {:error, :utility_unavailable}

      executable ->
        run(:ip, ["netns", "exec", namespace, executable] ++ prefix(name) ++ arguments)
    end
  end
end
