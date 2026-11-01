# @cc [owner:ghuntley,label:verification] zfs-guest-real-confined-execution
# This fixture MUST use source-built Lilly and the verified guest image, prove physical
# confinement, and keep all terminal bytes out of diagnostics. Its worker exit MUST NOT
# terminate the independently supervised VMM.
defmodule ZFSGuestFixture do
  alias Lilly.Host.{Collector, Image, Pool, PoolObserver, ZFS}
  alias Lilly.Terminal.Vsock
  alias Lilly.VM.{Boot, Config, Driver, Jail, Observation, Readiness, Spec, Unit}

  @type terminal :: %{socket: Vsock.socket(), control: Vsock.socket(), session_id: pos_integer()}

  @spec run() :: :ok
  def run do
    host = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
    pool_id = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"
    {:ok, identity} = ZFS.inspect_path("/pool")

    {:ok, pool} =
      Pool.new(pool_id, "/pool", identity.filesystem_id,
        storage: OverallsProtocol.Storage.encode(identity.storage),
        host_id: host
      )

    {:ok, image} = Image.load(System.fetch_env!("ZFS_GUEST_IMAGE"))
    base_disk_bytes = max(image.manifest.minimum_disk_bytes, 3_221_225_472)
    grown_disk_bytes = base_disk_bytes + 1_073_741_824
    base_memory_bytes = max(image.manifest.minimum_memory_bytes, 536_870_912)
    grown_memory_bytes = base_memory_bytes + 268_435_456
    number = String.to_integer(System.fetch_env!("ZFS_VM"))
    # 130..134 belong to the clone-matrix variant's resized and chained copies;
    # 135..137 to its same-pool block copies (ADR-0145).
    true = number in 101..119 or number in 130..137
    id = "dddddddd-dddd-4ddd-8ddd-" <> String.pad_leading(to_string(number), 12, "0")

    action = System.fetch_env!("ZFS_ACTION")
    generation = System.fetch_env!("ZFS_GENERATION") |> String.to_integer()
    downsized? = String.starts_with?(action, "downsized-")
    resized? = String.starts_with?(action, "resized-") or downsized?

    action =
      action |> String.replace_prefix("resized-", "") |> String.replace_prefix("downsized-", "")

    {:ok, spec} =
      Spec.new(%{
        id: id,
        image_id: image.id,
        pool_id: pool_id,
        profile: if(number in [111, 117, 118], do: :inception, else: :customer),
        slot: number + 2,
        vcpu: if(number in [107, 108], do: 2, else: 1),
        memory_bytes:
          if(number in [107, 108],
            do: max(base_memory_bytes, 1_073_741_824),
            else: base_memory_bytes
          ),
        # The exact manifest determines the base; resize still grows it by one GiB.
        disk_bytes: if(number in [107, 108], do: grown_disk_bytes, else: base_disk_bytes)
      })

    spec =
      if resized?,
        do: %{spec | vcpu: 2, memory_bytes: grown_memory_bytes, disk_bytes: grown_disk_bytes},
        else: spec

    # Android lifecycle probes restart the resized shape after the explicit
    # resize step; keep the persisted descriptor and launch spec identical.
    spec =
      if System.get_env("ZFS_GUEST_ANDROID") == "1" and generation >= 4,
        do: %{spec | vcpu: 2, memory_bytes: grown_memory_bytes, disk_bytes: grown_disk_bytes},
        else: spec

    spec = if downsized?, do: %{spec | vcpu: 1, memory_bytes: base_memory_bytes}, else: spec

    tools = System.fetch_env!("ZFS_RELEASE_METADATA") |> File.read!() |> JSON.decode!()
    {:ok, network} = Lilly.Network.Config.new(host, "eth1", [], "/var/lib/lilly/network")

    # Storage-only fixture: satisfy the private input prerequisite with synthetic
    # SMTP. This scenario does not deliver mail or establish stack bootstrap.
    :ok =
      Lilly.Host.PrivateFiles.write(
        "/run/inception-storage-test",
        "smtp.json",
        JSON.encode!(%{
          "version" => 1,
          "host" => "smtp.example.test",
          "port" => 587,
          "username" => "fixture",
          "password" => "synthetic-storage-fixture",
          "from" => "dev@example.test",
          "tls" => "starttls"
        })
      )

    {:ok, config} =
      Config.new(%{
        state_dir: "/var/lib/lilly/vms",
        firecracker_logging: true,
        inception_smtp_file: "/run/inception-storage-test/smtp.json",
        inception_image_id: image.id,
        network: network,
        guest_trust_roots:
          System.fetch_env!("ZFS_GUEST_TRUST_ROOTS")
          |> String.split(",", trim: true)
          |> Enum.map(&File.read!/1),
        firecracker: tools["firecracker"],
        jailer: tools["jailer"],
        unshare: tools["unshare"]
      })

    case action do
      recovery when recovery in ["actor-recovery", "beam-crash", "beam-recover"] ->
        :ok = Lilly.Network.setup(network)
        Code.require_file("/etc/zfs-actor-recovery.exs")

        mode =
          case recovery do
            "actor-recovery" -> :actor
            "beam-crash" -> :beam_crash
            "beam-recover" -> :beam_recover
          end

        :ok = ZFSGuestActorRecovery.run(config, pool, image, spec, generation, mode)

      "backup-config" ->
        File.write!(
          "/run/backup-config.json",
          JSON.encode!(%{
            host_id: host,
            vm_state_directory: config.state_dir,
            minimum_free_bytes: 134_217_728,
            pools: [
              %{
                id: pool.id,
                path: pool.path,
                filesystem_id: pool.filesystem_id,
                storage: OverallsProtocol.Storage.encode(pool.storage)
              }
            ]
          })
        )

      "backup-flush-off" ->
        console(config, spec, "systemctl stop lilly-flush.service")

      "template-post-import" ->
        Code.require_file("/etc/zfs-template-post-import.exs")
        :ok = ZFSGuestTemplatePostImport.run(pool, image, config, spec)

      "template-drift-replacement" ->
        Code.require_file("/etc/zfs-template-post-import.exs")
        :ok = ZFSGuestTemplatePostImport.replace_drifted(pool, image, config, spec)

      "backup-flush-on" ->
        console(config, spec, "systemctl start lilly-flush.service")

      "data-write" ->
        console(
          config,
          spec,
          "test $(blockdev --getsize64 /dev/vdb) = 274877906944 && printf inception-data | dd of=/dev/vdb bs=14 count=1 conv=notrunc,fsync status=none"
        )

      "data-read" ->
        console(
          config,
          spec,
          "test $(blockdev --getsize64 /dev/vdb) = 274877906944 && test \"$(dd if=/dev/vdb bs=14 count=1 status=none)\" = inception-data"
        )

      "clone" ->
        Code.require_file("/etc/zfs-cloning.exs")
        :ok = apply(ZFSGuestCloneFixture, :run, [config, pool, image, spec, generation])

      "clone-matrix" ->
        # The clone-matrix variant bootstraps from the same driver actions; the
        # explicit target identity lets the driver boot an adopted copy by number.
        target = System.fetch_env!("ZFS_TARGET") |> String.to_integer()
        true = target in 100..200 and target != number
        Code.require_file("/etc/zfs-clone-matrix.exs")
        :ok = ZFSGuestCloneMatrixFixture.run(config, pool, image, spec, generation, target)

      "resize-interrupt" ->
        :ok = Driver.stop(config, pool, spec, generation: generation)
        target = %{spec | vcpu: 2, memory_bytes: grown_memory_bytes, disk_bytes: grown_disk_bytes}

        {:error, :resize_unconfirmed} =
          Lilly.Host.Storage.locked(pool, fn ->
            Lilly.Host.ZFSDataset.resize(pool, spec, target, spec.id, fn ->
              {:ok, _} =
                Lilly.Host.Command.run(:truncate, [
                  "--size",
                  to_string(target.disk_bytes),
                  "--",
                  Lilly.VM.Disk.path(pool, spec)
                ])

              {:ok, _} = Lilly.Host.Command.run(:sync, ["--", Lilly.VM.Disk.path(pool, spec)])
              {:error, :injected_interruption}
            end)
          end)

        true = File.stat!(Lilly.VM.Disk.path(pool, spec)).size == target.disk_bytes

      "resize-publish-interrupt" ->
        # Model a process dying after publishing one marker but before its sibling
        # and GUID-bound claim. Only an existing exact transition permits recovery.
        target = %{spec | vcpu: 2, memory_bytes: grown_memory_bytes, disk_bytes: grown_disk_bytes}
        directory = Lilly.Host.ZFSDataset.metadata_directory(pool, spec)

        {:ok, bytes} =
          Lilly.Host.PrivateFiles.read_secret(
            Path.join(directory, "resize-" <> spec.id <> ".json")
          )

        %{"source" => %{"binding" => %{"spec" => source}}} = JSON.decode!(bytes)
        true = source == Spec.encode(spec)

        :ok =
          Lilly.Host.Storage.locked(pool, fn ->
            Lilly.Host.PrivateFiles.write(
              directory,
              "disk.json",
              JSON.encode!(Spec.encode(target))
            )
          end)

      "resize-down" ->
        :ok = Driver.stop(config, pool, spec, generation: generation)
        target = %{spec | vcpu: 1, memory_bytes: base_memory_bytes}

        :ok =
          Driver.resize(config, pool, spec, target,
            generation: generation + 1,
            request_id: "11111111-1111-4111-8111-111111111111"
          )

        {:ok, :stopped} = Unit.status(target)

      "check-downshape" ->
        console(
          config,
          spec,
          "test $(nproc) = 1 && test $(blockdev --getsize64 /dev/vda) = #{grown_disk_bytes} && test $(awk '/MemTotal/ {print $2}' /proc/meminfo) -lt #{div(base_memory_bytes, 1024)}"
        )

      "resize" ->
        target = %{spec | vcpu: 2, memory_bytes: grown_memory_bytes, disk_bytes: grown_disk_bytes}

        :ok =
          Driver.resize(config, pool, spec, target, generation: generation, request_id: spec.id)

        :ok =
          Driver.resize(config, pool, spec, target, generation: generation, request_id: spec.id)

        {:ok, :stopped} = Unit.status(target)
        {:error, _} = Driver.start(config, pool, image, spec, generation: generation + 1)

      "check-shape" ->
        console(
          config,
          spec,
          "test $(nproc) = 2 && test $(blockdev --getsize64 /dev/vda) = #{grown_disk_bytes} && test $(df -B1 --output=size / | tail -1) -gt #{base_disk_bytes} && test $(awk '/MemTotal/ {print $2}' /proc/meminfo) -gt #{div(base_memory_bytes, 1024) + 65_536}"
        )

      "delete-source-snapshots" ->
        Code.require_file("/etc/zfs-restoration.exs")
        apply(ZFSGuestRestorationFixture, :delete_source, [config, pool, image, spec])

      "restore-cancelled-source" ->
        Code.require_file("/etc/zfs-restoration.exs")
        apply(ZFSGuestRestorationFixture, :run, [config, pool, image, spec])

      "restore-cancelled-empty-source" ->
        Code.require_file("/etc/zfs-restoration.exs")
        apply(ZFSGuestRestorationFixture, :run, [config, pool, image, spec, false])

      "delete-restored-source" ->
        :ok = delete_restored(config, pool, spec, deadline(60_000))

      "source-" <> _ = action ->
        Code.require_file("/etc/zfs-source.exs")
        apply(ZFSGuestSourceFixture, :run, [config, pool, spec, generation, action])

      "relocation-readiness" ->
        Code.require_file("/etc/zfs-readiness.exs")
        apply(ZFSGuestReadinessFixture, :run, [config, pool, image, spec])

      "restart-contention" ->
        Code.require_file("/etc/zfs-restart.exs")
        apply(ZFSGuestRestartFixture, :run, [config, pool, spec, generation])

      "start" ->
        :ok = Lilly.Network.setup(network)
        :ok = start(config, pool, image, spec, generation, deadline(60_000))
        await(fn -> Observation.running?(config, pool, spec) end, deadline(30_000))
        {:ok, boot} = Boot.read(Path.join(config.state_dir, spec.id))
        true = boot.generation == generation and boot.execution_epoch == 1

        case Driver.trust(config, pool, spec, execution_epoch: 1, generation: generation) do
          :ok ->
            :ok

          {:error, _} ->
            diagnose_readiness(config, pool, spec)
            raise "Guest trust failed; bounded probe results above, terminal bytes withheld"
        end

        # The two-disk scenario deliberately uses the ordinary image so this
        # suite proves storage independently of Inception's application stack.
        ready =
          cond do
            System.get_env("ZFS_GUEST_UBUNTU") == "1" ->
              # @cc [owner:ghuntley,label:verification;security] isolated-ubuntu-storage-trust
              # This storage fixture has no Audi authority. It MUST verify the
              # boot trust and network units while SSH remains closed, without
              # presenting this VM as a successful full-readiness observation.
              await(
                fn ->
                  diagnostic_console(
                    config,
                    spec,
                    "systemctl is-active --quiet overalls-guest-trust.service && " <>
                      "systemctl is-active --quiet lilly-network.service && " <>
                      "systemctl is-active --quiet lilly-private-dns.service && " <>
                      "systemctl is-active --quiet nix-daemon.service && " <>
                      "test -S /run/docker.sock && " <>
                      "test ! -e /run/overalls-ssh-ready && " <>
                      "! systemctl is-active --quiet ssh.service"
                  ) == :pass
                end,
                deadline(120_000)
              )

              :ok

            System.get_env("ZFS_GUEST_PRIVATE_NIXOS") == "1" ->
              # @cc [owner:ghuntley,label:verification;security] isolated-nixos-private-boot-trust
              # The production-shaped NixOS boot-profile image has no Audi
              # authority either. It MUST verify boot trust, network and private
              # DNS units while SSH remains closed, without claiming readiness.
              await(
                fn ->
                  diagnostic_console(
                    config,
                    spec,
                    "systemctl is-active --quiet overalls-guest-trust.service && " <>
                      "systemctl is-active --quiet lilly-network.service && " <>
                      "systemctl is-active --quiet lilly-private-dns.service && " <>
                      "test ! -e /run/overalls-ssh-ready && " <>
                      "! systemctl is-active --quiet sshd.service"
                  ) == :pass
                end,
                deadline(120_000)
              )

              :ok

            number in [111, 117, 118] ->
              case Readiness.wait(
                     Path.join(Jail.root(pool, spec), "v.sock"),
                     Boot.expectation(boot)
                   ) do
                {:ok, _} -> :ok
                error -> error
              end

            true ->
              # @cc [owner:ghuntley,label:verification;recovery] guest-readiness-durable-before-effects
              # A fully ready fixture MUST persist the current boot's production
              # completion receipt before later effects reconcile it as running.
              # A socket readiness exchange alone MUST NOT establish that receipt.
              Driver.provisioned(config, pool, spec, execution_epoch: 1, generation: generation)
          end

        case ready do
          :ok ->
            :ok

          {:error, _} ->
            diagnose_readiness(config, pool, spec)
            raise "Guest readiness failed; bounded probe results above, terminal bytes withheld"
        end

        true = Observation.running?(config, pool, spec)

        # @cc [owner:ghuntley,label:verification] guest-toolset-boot-smoke
        # Every booted guest MUST expose the reviewed default toolset: the Docker
        # compatibility alias and socket, live Podman storage, Podman Compose, Nix
        # and the CLI/network tools. Checks MUST run as root inside the real image.
        if System.get_env("ZFS_GUEST_UBUNTU") == "1" do
          console(
            config,
            spec,
            ". /etc/os-release && test \"$ID\" = ubuntu && test \"$VERSION_ID\" = 26.04 && " <>
              "test $(id -u) = 0 && hello >/dev/null && " <>
              "test $(stat -c %a /etc/myapp/config.json) = 640 && " <>
              "python3 -c 'import json; assert json.load(open(\"/etc/myapp/config.json\"))[\"configured_by\"] == \"nix\"' && " <>
              "openssl verify -CAfile /etc/ssl/certs/ca-certificates.crt /usr/local/share/ca-certificates/overalls-platform/overalls-0.crt >/dev/null && " <>
              "systemctl is-active --quiet overalls-guest-trust.service && " <>
              "systemctl is-active --quiet lilly-private-dns.service && " <>
              "resolvectl domain eth0 | grep -q '~internal' && " <>
              "resolvectl dns eth0 | grep -q 169.254.254.1 && " <>
              "test $(df -B1 --output=size / | tail -1) -gt 1800000000 && " <>
              "(test ! -e /proc/sys/net/ipv6/conf/all/disable_ipv6 || test $(cat /proc/sys/net/ipv6/conf/all/disable_ipv6) = 1) && " <>
              "docker --version >/dev/null && test -S /run/docker.sock && podman info >/dev/null && " <>
              "podman-compose --version >/dev/null && nix --version >/dev/null && " <>
              "systemctl is-active --quiet nix-daemon.service && " <>
              guest_toolset_commands() <>
              " && " <>
              "! systemctl is-active --quiet ssh.service"
          )
        else
          console(
            config,
            spec,
            "test -f /etc/NIXOS && test $(id -u) = 0 && test ! -e /nix-path-registration && " <>
              "nix-store -q --hash /run/current-system >/dev/null && " <>
              "docker --version >/dev/null && test -S /run/docker.sock && podman info >/dev/null && " <>
              "podman-compose --version >/dev/null && nix --version >/dev/null && " <>
              guest_toolset_commands()
          )
        end

        console(config, spec, guest_prompt_commands())
        console(config, spec, manually_created_user_prompt_commands())

      "android-start" ->
        :ok = Lilly.Network.setup(network)
        :ok = start(config, pool, image, spec, generation, deadline(120_000))
        await(fn -> Observation.running?(config, pool, spec) end, deadline(60_000))
        {:ok, boot} = Boot.read(Path.join(config.state_dir, spec.id))

        :ok =
          case Readiness.wait(
                 Path.join(Jail.root(pool, spec), "v.sock"),
                 Boot.expectation(boot),
                 180_000
               ) do
            {:ok, _receipt} ->
              :ok

            error ->
              # Preserve bounded guest-side evidence when the emulator does not
              # publish readiness.  This is intentionally limited to service
              # state and process metadata; it never includes ADB keys or
              # terminal/display bytes.
              _ =
                diagnostic_console(
                  config,
                  spec,
                  "systemctl --no-pager --full status overalls-android-emulator.service overalls-android-display.service overalls-android-display-vsock.service || true; " <>
                    "tail -n 80 /run/overalls-android/xvfb.log 2>/dev/null || true; " <>
                    "pgrep -af '/emulator/emulator' || true"
                )

              boot_log = Unit.boot_log(config, spec)

              case File.read(boot_log) do
                {:ok, bytes} ->
                  # Firecracker's bounded serial stream contains only kernel and
                  # systemd boot diagnostics by contract. Keep the tail small so
                  # a failed test cannot turn this into an unbounded log sink.
                  IO.puts(
                    "android-boot-log-tail:\n" <>
                      binary_part(
                        bytes,
                        max(byte_size(bytes) - 4096, 0),
                        min(byte_size(bytes), 4096)
                      )
                  )

                {:error, _reason} ->
                  :ok
              end

              raise "Android guest readiness failed: #{inspect(error)}"
          end

        :pass = wait_android_ready(config, spec, 60)

        :pass =
          diagnostic_console(
            config,
            spec,
            "systemctl is-active --quiet overalls-android-emulator.service && " <>
              "systemctl is-active --quiet overalls-android-display.service && " <>
              "systemctl is-active --quiet overalls-android-display-vsock.service && " <>
              "test ! -e /dev/kvm && " <>
              "pgrep -af '/emulator/emulator' | grep -F -- '-no-accel' && " <>
              "pgrep -af '/emulator/emulator' | grep -F -- '-gpu swiftshader_indirect' && " <>
              "ss -ltn | grep -F ':5901' && " <>
              "adb -s emulator-5554 shell getprop ro.kernel.qemu | tr -d '\\r' | grep -Fx 1"
          )

        IO.puts(JSON.encode!(%{image_id: image.id, generation: generation, android: true}))

      "android-stop" ->
        :ok = Driver.stop(config, pool, spec, generation: generation)

      "android-resize" ->
        # Exercise the same stopped-unit resize path used by production Android
        # machines.  The target grows CPU, memory and disk while preserving the
        # image, pool and guest network identity.
        target = %{
          spec
          | vcpu: 2,
            memory_bytes: spec.memory_bytes + 268_435_456,
            disk_bytes: spec.disk_bytes + 1_073_741_824
        }

        :ok =
          Driver.resize(config, pool, spec, target,
            request_id: "android-resize-#{generation}",
            revision: generation
          )

      "android-delete" ->
        :ok = Driver.delete(config, pool, spec, generation: generation)

      "reject-readiness" ->
        {:error, :readiness_unconfirmed} =
          Driver.ready(config, pool, spec,
            execution_epoch: 2,
            generation: generation,
            timeout: 300
          )

        {:error, :readiness_unconfirmed} =
          Driver.ready(config, pool, spec,
            execution_epoch: 1,
            generation: generation + 1,
            timeout: 300
          )

        {:ok, boot} = Boot.read(Path.join(config.state_dir, spec.id))
        expected = Boot.expectation(boot)

        for stale <- [
              Map.put(expected, :execution_epoch, expected.execution_epoch + 1),
              Map.put(expected, :boot_challenge, String.duplicate("0", 64))
            ] do
          {:error, :readiness_timeout} =
            Readiness.wait(Path.join(Jail.root(pool, spec), "v.sock"), stale, 300)
        end

      "trust-verify" ->
        # @cc [owner:ghuntley,label:verification;security] zfs-guest-trust-store-rotation
        # After a boot's delivery, the guest's system bundle MUST hold every
        # currently delivered root and none of the listed retired roots; on
        # Ubuntu the OpenSSL CApath hash links and the managed root files MUST
        # agree, so the prebuilt-store no-op and full rebuild paths both leave
        # a coherent store. Only fixed verdicts leave the guest.
        absent =
          System.get_env("ZFS_GUEST_TRUST_ABSENT", "")
          |> String.split(",", trim: true)
          |> Enum.map(&File.read!/1)

        :pass =
          diagnostic_console(
            config,
            spec,
            trust_verification(
              config.guest_trust_roots,
              absent,
              System.get_env("ZFS_GUEST_UBUNTU") == "1"
            )
          )

      "coding-clis" ->
        # Native help/version commands and system configuration must work for
        # root and an ordinary user, before and after collection in the guest.
        for phase <- ["before-gc", "after-gc"] do
          if phase == "after-gc", do: console(config, spec, "nix-store --gc >/dev/null 2>&1")

          console_steps(
            config,
            spec,
            Enum.map(coding_cli_steps(), fn {name, command} ->
              {"#{phase} root #{name}", "bash -lc " <> shell_quote(command)}
            end) ++
              Enum.map(manually_created_user_coding_cli_steps(), fn {name, command} ->
                {"#{phase} new-user #{name}", command}
              end)
          )
        end

      "observe" ->
        true = Observation.running?(config, pool, spec)
        :ok = Driver.adopt(config, pool, spec, execution_epoch: 1, generation: generation)

      "cpu-pressure" ->
        console(config, spec, "yes >/dev/null & yes >/dev/null & true")

      "cpu-release" ->
        console(config, spec, "pkill -x yes || true")

      "headroom" ->
        alias Lilly.Host.{Inventory, Limits, Usage}
        {:ok, inventory} = Inventory.read()
        {:ok, limits} = Limits.read("/sys/fs/cgroup", "/sys/fs/cgroup/lilly.slice", inventory)

        {nil, previous} =
          Usage.sample(
            "/sys/fs/cgroup",
            "/sys/fs/cgroup/lilly.slice",
            inventory,
            limits,
            nil,
            %{}
          )

        Process.sleep(1000)
        {:ok, inventory} = Inventory.read()

        {usage, _} =
          Usage.sample(
            "/sys/fs/cgroup",
            "/sys/fs/cgroup/lilly.slice",
            inventory,
            limits,
            previous,
            %{}
          )

        true = is_map(usage)
        IO.puts(JSON.encode!(usage))

      "write" ->
        console(config, spec, "printf zfs-guest-flushed-#{generation} >/root/zfs-marker && sync")

      "read" ->
        console(
          config,
          spec,
          "test \"$(cat /root/zfs-marker)\" = zfs-guest-flushed-#{generation}"
        )

      "stop" ->
        :ok = Driver.stop(config, pool, spec, generation: generation)

      "delete" ->
        :ok = Driver.delete(config, pool, spec, generation: generation)

      "reject-start" ->
        {:error, _} = Driver.start(config, pool, image, spec, generation: generation)

      "snapshot" ->
        # @cc [owner:ghuntley,label:verification] zfs-fixture-settled-pool-snapshot
        # A busy pool entry (lock held or usage moving, ADR-0031) is transient
        # identity-only evidence. Allocation assertions MUST read a settled
        # observation, retried within a bounded deadline, never a busy entry.
        # Collection reads pool entries only from the background pool observer
        # (contract pool-reads-do-not-delay-sample); this one-shot BEAM runs its own.
        view = :zfs_guest_fixture_pool_observer
        {:ok, _} = PoolObserver.start_link({[pool], [view: view, interval_ms: 1000]})
        snapshot = settled_snapshot(pool, image, view, deadline(60_000))

        IO.puts(
          JSON.encode!(%{snapshot | storage: OverallsProtocol.Storage.encode(snapshot.storage)})
        )
    end

    :ok
  end

  @spec settled_snapshot(Pool.t(), Image.t(), atom(), integer()) :: map()
  defp settled_snapshot(pool, image, view, until) do
    {:ok, report, _} =
      Collector.sample([pool], "/sys/fs/cgroup/lilly.slice", nil, 1, [image], %{}, %{}, view)

    [snapshot] = report.pools

    cond do
      not Map.get(snapshot, :busy, false) ->
        snapshot

      System.monotonic_time(:millisecond) >= until ->
        raise "pool snapshot stayed busy past the fixture deadline"

      true ->
        Process.sleep(500)
        settled_snapshot(pool, image, view, until)
    end
  end

  # @cc [owner:ghuntley,label:verification] restored-source-delete-retries-same-authority
  # Unconfirmed dataset cleanup MUST retry the same restored-source epoch and
  # generation within a fixed deadline. Only Driver.delete success may finish;
  # unexpected failures and persistent incomplete cleanup MUST fail the fixture.
  defp delete_restored(config, pool, spec, until) do
    case Driver.delete(config, pool, spec, execution_epoch: 2, generation: 4) do
      :ok ->
        :ok

      {:error, :zfs_dataset_cleanup_unconfirmed} ->
        if System.monotonic_time(:millisecond) >= until,
          do: raise("restored source cleanup remained unconfirmed")

        Process.sleep(1000)
        delete_restored(config, pool, spec, until)
    end
  end

  # @cc [owner:ghuntley,label:verification;security] readiness-fixture-bounded-diagnostics
  # Failure diagnostics MUST expose only fixed probe labels and pass/fail/unavailable,
  # never guest terminal bytes, boot challenges, command output or journal contents.
  defp diagnose_readiness(config, pool, spec) do
    socket_path = Path.join(Jail.root(pool, spec), "v.sock")
    IO.puts("readiness_probe:socket_present:#{File.exists?(socket_path)}")

    probes = [
      multi_user: "systemctl is-active --quiet multi-user.target",
      multi_user_job: "systemctl list-jobs --no-legend | grep -q multi-user.target",
      network_unit: "systemctl is-active --quiet lilly-network.service",
      trust_unit: "systemctl is-active --quiet overalls-guest-trust.service",
      trust_failed: "systemctl is-failed --quiet overalls-guest-trust.service",
      private_dns: "systemctl is-active --quiet lilly-private-dns.service",
      ssh_ready: "test -f /run/overalls-ssh-ready",
      ssh_unit: "systemctl is-active --quiet ssh.service",
      trust_listener: "ss -l --vsock | grep -q 1030",
      trust_bundle: "test -s /etc/ssl/certs/ca-certificates.crt",
      readiness_unit: "systemctl is-active --quiet lilly-readiness.service",
      vsock_module: "test -d /sys/module/vmw_vsock_virtio_transport",
      listener: "ss -l --vsock | grep -q 1024",
      root_write:
        "touch /.lilly-fixture-write && sync /.lilly-fixture-write && rm /.lilly-fixture-write"
    ]

    for {label, command} <- probes do
      result = diagnostic_console(config, spec, command)
      IO.puts("readiness_probe:#{label}:#{result}")
    end
  end

  defp diagnostic_console(config, spec, command) do
    with {:ok, terminal} <- connect_terminal(config, spec, deadline(2_000)) do
      try do
        marker = "PROBE_" <> Base.encode16(:crypto.strong_rand_bytes(8))

        :ok =
          Vsock.write(
            terminal.socket,
            "\nif (" <>
              command <>
              ") >/dev/null 2>&1; then printf '\\n" <>
              marker <> ":pass\\n'; else printf '\\n" <> marker <> ":fail\\n'; fi\n"
          )

        diagnostic_result(terminal.socket, marker, deadline(10_000), "")
      after
        close_terminal(terminal)
      end
    else
      _ -> :unavailable
    end
  end

  @spec wait_android_ready(Config.t(), Spec.t(), pos_integer()) :: :pass | :fail
  defp wait_android_ready(config, spec, attempts) when attempts > 0 do
    result =
      diagnostic_console(
        config,
        spec,
        "systemctl is-active --quiet overalls-android-emulator.service && " <>
          "adb -s emulator-5554 shell getprop sys.boot_completed 2>/dev/null | " <>
          "tr -d '\\r' | grep -qx 1"
      )

    case result do
      :pass ->
        :pass

      _ ->
        Process.sleep(1_000)
        wait_android_ready(config, spec, attempts - 1)
    end
  end

  defp wait_android_ready(_config, _spec, 0), do: :fail

  defp diagnostic_result(socket, marker, until, tail) do
    if System.monotonic_time(:millisecond) >= until do
      :unavailable
    else
      case :gen_tcp.recv(socket, 0, 1000) do
        {:ok, bytes} ->
          body = :binary.replace(tail <> bytes, "\r", "", [:global])

          cond do
            :binary.match(body, "\n#{marker}:pass\n") != :nomatch ->
              :pass

            :binary.match(body, "\n#{marker}:fail\n") != :nomatch ->
              :fail

            true ->
              count = min(byte_size(body), 128)

              diagnostic_result(
                socket,
                marker,
                until,
                binary_part(body, byte_size(body) - count, count)
              )
          end

        {:error, :timeout} ->
          diagnostic_result(socket, marker, until, tail)

        _ ->
          :unavailable
      end
    end
  end

  # Retry only the production driver's pre-launch storage contention result;
  # preserve the exact generation and all retained files across attempts.
  defp start(config, pool, image, spec, generation, until) do
    ready =
      Path.join(Lilly.Host.ZFSDataset.metadata_directory(pool, spec), "disk-ready.json")

    options = [generation: generation]

    result =
      if File.exists?(ready),
        do: Driver.restart(config, pool, spec, generation: generation),
        else: Driver.start(config, pool, image, spec, options)

    case result do
      {:error, :storage_busy} = result ->
        if System.monotonic_time(:millisecond) < until do
          Process.sleep(100)
          start(config, pool, image, spec, generation, until)
        else
          result
        end

      result ->
        result
    end
  end

  @spec console(Config.t(), Spec.t(), String.t()) :: :ok
  defp console(config, spec, command) do
    {:ok, terminal} = connect_terminal(config, spec, deadline(120_000))

    try do
      ready = "SHELL_" <> Base.encode16(:crypto.strong_rand_bytes(12))
      :ok = Vsock.write(terminal.socket, "\nprintf '\\n%s%s\\n' #{ready} _READY\n")
      wait(terminal.socket, "\n#{ready}_READY\n", deadline(120_000), "")
      marker = "ZFS_" <> Base.encode16(:crypto.strong_rand_bytes(12))
      :ok = Vsock.write(terminal.socket, command <> " && printf '\\n#{marker}:OK\\n'\n")
      wait(terminal.socket, "\n#{marker}:OK\n", deadline(60_000), "")
    after
      close_terminal(terminal)
    end
  end

  # @cc [owner:ghuntley,label:verification;security] zfs-fixture-step-status
  # Multi-step guest assertions MUST report the failing step name and its exit
  # status (or a step timeout) while still withholding every terminal byte.
  @spec console_steps(Config.t(), Spec.t(), [{String.t(), String.t()}]) :: :ok
  defp console_steps(config, spec, steps) do
    {:ok, terminal} = connect_terminal(config, spec, deadline(120_000))

    try do
      ready = "SHELL_" <> Base.encode16(:crypto.strong_rand_bytes(12))
      :ok = Vsock.write(terminal.socket, "\nprintf '\\n%s%s\\n' #{ready} _READY\n")
      wait(terminal.socket, "\n#{ready}_READY\n", deadline(120_000), "")

      Enum.each(steps, fn {name, command} ->
        marker = "ZFS_" <> Base.encode16(:crypto.strong_rand_bytes(12))
        :ok = Vsock.write(terminal.socket, "( #{command} ); printf '\\n#{marker}:%s\\n' $?\n")

        case wait_status(terminal.socket, marker, deadline(60_000), "") do
          0 -> :ok
          :timeout -> raise "Guest step #{name} timed out; terminal bytes withheld"
          code -> raise "Guest step #{name} exited #{code}; terminal bytes withheld"
        end
      end)
    after
      close_terminal(terminal)
    end
  end

  defp wait_status(socket, marker, until, tail) do
    if System.monotonic_time(:millisecond) >= until do
      :timeout
    else
      case :gen_tcp.recv(socket, 0, 1000) do
        {:ok, bytes} ->
          body = :binary.replace(tail <> bytes, "\r", "", [:global])

          case Regex.run(~r/\n#{marker}:(\d{1,3})\n/, body) do
            [_, code] ->
              String.to_integer(code)

            nil ->
              keep = min(byte_size(body), byte_size(marker) + 8)
              wait_status(socket, marker, until, binary_part(body, byte_size(body) - keep, keep))
          end

        {:error, :timeout} ->
          wait_status(socket, marker, until, tail)

        _ ->
          raise "Guest console closed; terminal bytes withheld"
      end
    end
  end

  # @cc [owner:ghuntley,label:verification;security] zfs-fixture-terminal-current-boot
  # Real-guest assertions MUST authenticate terminald with the persisted current
  # boot identity and an isolated PTY. The fixture MUST retire that PTY and MUST
  # NOT print its authentication material or terminal bytes.
  @spec connect_terminal(Config.t(), Spec.t(), integer()) ::
          {:ok, terminal()} | {:error, :terminal_unavailable}
  defp connect_terminal(config, spec, until) do
    directory = Path.join(config.state_dir, spec.id)

    result =
      with {:ok, intent} <- Lilly.VM.Intent.read(directory),
           {:ok, boot} <-
             Boot.current(
               directory,
               spec.id,
               {intent.execution_epoch, intent.generation}
             ),
           {:ok, bytes} <-
             Lilly.Host.PrivateFiles.read_secret(Path.join(directory, "vm.json")),
           {:ok, %{"pool_path" => pool}} when is_binary(pool) <- JSON.decode(bytes),
           identity =
             Map.put(
               boot,
               :uds_path,
               Path.join([pool, ".lilly-jails", "firecracker", spec.id, "root", "v.sock"])
             ),
           {:ok, control} <- Vsock.connect(identity, timeout: 2_000) do
        create_terminal(control, identity)
      else
        _ -> {:error, :terminal_unavailable}
      end

    case result do
      {:error, :terminal_unavailable} = error ->
        if System.monotonic_time(:millisecond) < until do
          Process.sleep(100)
          connect_terminal(config, spec, until)
        else
          error
        end

      other ->
        other
    end
  end

  @spec create_terminal(Vsock.socket(), Vsock.identity()) ::
          {:ok, terminal()} | {:error, :terminal_unavailable}
  defp create_terminal(control, identity) do
    with {:ok, created} <- Vsock.create(control, "root", "xterm-256color", 80, 24),
         {:ok, attached} <-
           Vsock.attach(identity, created.guest_session_id, created.attach_token, :rw, 0) do
      {:ok, %{socket: attached.socket, control: control, session_id: created.guest_session_id}}
    else
      _ ->
        Vsock.close(control)
        {:error, :terminal_unavailable}
    end
  end

  @spec close_terminal(terminal()) :: :ok
  defp close_terminal(terminal) do
    _ = Vsock.kill(terminal.control, terminal.session_id)
    Vsock.close(terminal.socket)
    Vsock.close(terminal.control)
  end

  # Default-toolset presence check shared by both images; the chain exits
  # nonzero when any reviewed default command is missing from the root PATH.
  @bundle_check """
  import base64, ssl, sys
  context = ssl.create_default_context(cafile="/etc/ssl/certs/ca-certificates.crt")
  loaded = {bytes(der) for der in context.get_ca_certs(binary_form=True)}
  verdicts = []
  for argument in sys.argv[1:]:
      kind, encoded = argument.split(":", 1)
      der = ssl.PEM_cert_to_DER_cert(base64.b64decode(encoded).decode())
      verdicts.append((der in loaded) == (kind == "P"))
  sys.exit(0 if verdicts and all(verdicts) else 1)
  """

  @spec trust_verification([binary()], [binary()], boolean()) :: String.t()
  defp trust_verification(present, absent, ubuntu?) do
    arguments =
      Enum.map(present, &("P:" <> Base.encode64(&1))) ++
        Enum.map(absent, &("A:" <> Base.encode64(&1)))

    bundle =
      "python3 -c \"$(printf %s #{Base.encode64(@bundle_check)} | base64 -d)\" " <>
        Enum.join(arguments, " ")

    capath =
      for {root, kind} <- Enum.map(present, &{&1, :present}) ++ Enum.map(absent, &{&1, :absent}) do
        negate = if kind == :present, do: "", else: "! "

        "printf %s #{Base.encode64(root)} | base64 -d > /run/zfs-trust-check.pem && " <>
          negate <> "openssl verify -CApath /etc/ssl/certs /run/zfs-trust-check.pem"
      end

    if ubuntu? do
      Enum.join(
        [
          bundle,
          "test $(find /usr/local/share/ca-certificates/overalls-platform -type f | wc -l) = #{length(present)}"
          | capath
        ],
        " && "
      )
    else
      bundle
    end
  end

  @spec guest_toolset_commands() :: String.t()
  defp guest_toolset_commands do
    tools = [
      "curl",
      "wget",
      "tmux",
      "vim",
      "nvim",
      "less",
      "lsof",
      "jq",
      "rg",
      "hg",
      "git",
      "gh",
      "atop",
      "btop",
      "iotop",
      "ncdu",
      "sqlite3",
      "nslookup",
      "dig",
      "ping",
      "ip",
      "direnv",
      "devenv",
      "codex",
      "claude",
      "starship"
    ]

    Enum.map_join(tools, " && ", &"command -v #{&1} >/dev/null")
  end

  # @cc [owner:ghuntley,label:verification] guest-coding-cli-native-execution
  # Both real images MUST execute native Codex and Claude version/help commands
  # without provider authentication or a network connection. The login shell
  # MUST expose Ziggy system settings and verified CA trust before and after GC.
  @spec coding_cli_steps() :: [{String.t(), String.t()}]
  defp coding_cli_steps do
    settings = "/etc/zfs-coding-clis.py" |> File.read!() |> Base.encode64()

    [
      {"codex-version", "codex --version >/dev/null"},
      {"codex-help", "codex --help >/dev/null"},
      {"claude-version", "claude --version >/dev/null"},
      {"claude-help", "claude --help >/dev/null"},
      {"settings", "python3 -c \"$(printf %s #{settings} | base64 -d)\""}
    ]
  end

  # @cc [owner:ghuntley,label:verification] guest-coding-cli-user-login
  # A plain useradd account MUST execute both native clients with inherited
  # system configuration and CA trust. The fixture MUST remove its account and
  # home, including any client state created by the smoke commands.
  @spec manually_created_user_coding_cli_steps() :: [{String.t(), String.t()}]
  defp manually_created_user_coding_cli_steps do
    [{"create", "useradd -m coding-clis-fixture"}] ++
      Enum.map(coding_cli_steps(), fn {name, command} ->
        {name, "su - coding-clis-fixture -c " <> shell_quote(command)}
      end) ++
      [
        {"remove",
         "userdel -f -r coding-clis-fixture >/dev/null 2>&1 && " <>
           "! getent passwd coding-clis-fixture >/dev/null && test ! -e /home/coding-clis-fixture"}
      ]
  end

  # @cc [owner:ghuntley,label:verification] guest-root-starship-startup
  # Both real images MUST start root in Bash with an active Starship prompt hook,
  # including nested interactive login and non-login Bash. Noninteractive Bash
  # startup MUST preserve exact stdout, and package presence alone MUST NOT pass.
  @spec guest_prompt_commands() :: String.t()
  defp guest_prompt_commands do
    probe = starship_hook_commands()

    probe <>
      " && shopt -q login_shell && " <>
      "bash -ic '#{probe} && ! shopt -q login_shell' && " <>
      "bash -lic '#{probe} && shopt -q login_shell' && " <>
      "test \"$(bash -c \"printf prompt-clean\"; printf '!')\" = prompt-clean! && " <>
      "test \"$(bash -lc \"printf prompt-clean\"; printf '!')\" = prompt-clean!"
  end

  # @cc [owner:ghuntley,label:verification] guest-manual-user-starship-startup
  # A disposable user created by plain useradd MUST inherit executable Bash and
  # global Starship startup without fixture-written dotfiles or an explicit shell.
  # The fixture MUST remove this account and home after the probe.
  @spec manually_created_user_prompt_commands() :: String.t()
  defp manually_created_user_prompt_commands do
    "(useradd -m starship-fixture && " <>
      "trap \"userdel -f -r starship-fixture >/dev/null 2>&1 || exit 1\" EXIT && " <>
      "su - starship-fixture -c " <>
      shell_quote("bash -lic " <> shell_quote(starship_hook_commands())) <>
      ") && ! getent passwd starship-fixture >/dev/null && test ! -e /home/starship-fixture"
  end

  @spec starship_hook_commands() :: String.t()
  defp starship_hook_commands do
    "test -n \"$BASH_VERSION\" && test \"$STARSHIP_SHELL\" = bash && " <>
      "command -v starship >/dev/null && declare -F starship_precmd >/dev/null && " <>
      "[[ ${PROMPT_COMMAND[*]} == *starship_precmd* ]] && " <>
      "test \"$(readlink /proc/$$/exe)\" = \"$(readlink -f \"$(command -v bash)\")\" && " <>
      "test \"$(readlink -f \"$(getent passwd \"$(id -un)\" | cut -d: -f7)\")\" = " <>
      "\"$(readlink -f \"$(command -v bash)\")\""
  end

  @spec shell_quote(String.t()) :: String.t()
  defp shell_quote(value), do: "'" <> String.replace(value, "'", "'\\''") <> "'"

  defp wait(socket, marker, until, tail) do
    if System.monotonic_time(:millisecond) >= until,
      do: raise("Guest assertion timed out; terminal bytes withheld")

    case :gen_tcp.recv(socket, 0, 1000) do
      {:ok, bytes} ->
        body = :binary.replace(tail <> bytes, "\r", "", [:global])

        if :binary.match(body, marker) == :nomatch do
          count = min(byte_size(body), byte_size(marker))
          wait(socket, marker, until, binary_part(body, byte_size(body) - count, count))
        end

      {:error, :timeout} ->
        wait(socket, marker, until, tail)

      _ ->
        raise "Guest console closed; terminal bytes withheld"
    end
  end

  defp await(fun, until) do
    unless fun.() do
      if System.monotonic_time(:millisecond) >= until, do: raise("VMM readiness timed out")

      receive do
      after
        100 -> await(fun, until)
      end
    end
  end

  defp deadline(ms), do: System.monotonic_time(:millisecond) + ms
end

:ok = ZFSGuestFixture.run()
