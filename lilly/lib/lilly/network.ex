defmodule Lilly.Network do
  @moduledoc "Owned Linux network resources. Root-only; mutations serialize through an OS lock."
  require Lilly.Events
  alias Lilly.Host.{Command, Lock, PrivateFiles}
  alias Lilly.Network.{Config, FlowLabel, Guest, Policy}
  @type result :: :ok | {:error, atom()}

  @spec setup(Config.t()) :: result()
  def setup(config) do
    locked(config, fn ->
      with :ok <- claim(config),
           {:ok, "1\n"} <- Command.run(:sysctl, ["-n", "net.ipv4.ip_forward"]),
           :ok <- rules(config, "root.nft", Policy.root(config), :root),
           :ok <- ensure_namespace(config),
           :ok <- ensure_link(config),
           :ok <- Lilly.Network.ProxyRouting.setup(config),
           :ok <- rules(config, "router.nft", Policy.router(config), :namespace),
           :ok <- configure_link(config),
           :ok <- configure_private_services(config) do
        :ok
      else
        _ ->
          Lilly.Events.emit("lilly.network_setup_failed", reason: :network_setup_failed)
          {:error, :network_setup_failed}
      end
    end)
  end

  # @cc [owner:ghuntley,label:security] network-identity-before-tap-mutation
  # attach/2,3 MUST establish the existing host and per-VM network claims before configuring a TAP.
  # An address route owned by another TAP or a mismatched TAP identity must fail rather than be
  # adopted. Enabled Brady requires the matching running launch intent before
  # installing flow labels; missing intent MUST NOT produce an unlabeled launch.
  @spec attach(Config.t(), Guest.t()) :: result()
  @spec attach(Config.t(), Guest.t(), Lilly.VM.Intent.t() | nil) :: result()
  @spec attach(Config.t(), Guest.t(), Lilly.VM.Intent.t() | nil, OverallsProtocol.uuid() | nil) ::
          result()
  def attach(config, guest, intent \\ nil, vm_id \\ nil) do
    locked(config, fn ->
      with {:ok, labels} <- FlowLabel.rules(config, guest, intent),
           :ok <- existing_claim(config),
           :ok <- available_route(config, guest),
           :ok <- guest_claim(config, guest),
           :ok <- ensure_tap(config, guest),
           :ok <- rules(config, "#{guest.guard}.nft", Policy.guard(guest) <> labels, :namespace),
           :ok <- ns(config, :ip, ["addr", "replace", guest.gateway <> "/32", "dev", guest.tap]),
           :ok <- ns(config, :ip, ["link", "set", "dev", guest.tap, "up"]),
           :ok <- install_routes(config, guest) do
        network_attached(vm_id, guest)
      else
        _ -> {:error, :network_attach_failed}
      end
    end)
  end

  # @cc [owner:ghuntley,label:security;observability] network-effect-events-correlated
  # Guest network attach/detach events MUST carry only the command's VM
  # identifier and the placement-bound guest identity; TAP names, addresses,
  # nftables programs and native output MUST NOT be logged.
  defp network_attached(nil, _guest), do: :ok

  defp network_attached(vm_id, guest) do
    Lilly.Events.emit("lilly.network_attached", vm_id: vm_id, placement_id: guest.vm_id)

    :ok
  end

  # @cc [owner:ghuntley,label:security;recovery] running-flow-label-refresh
  # Callers MUST hold the VM lock and verify the current running incarnation.
  # Refresh MUST require existing host/guest claims and the matching active TAP.
  # It may only update the owned flow-label table, never attach, stop or restart
  # the guest, modify addresses/routes, or retag confirmed connections. The
  # shared network lock MAY wait at most two seconds for definite contention;
  # unconfirmed ownership MUST still fail closed.
  @spec refresh_labels(Config.t(), Guest.t(), Lilly.VM.Intent.t()) :: result()
  def refresh_labels(%Config{brady: nil}, _, _), do: :ok

  def refresh_labels(config, guest, intent) do
    locked(config, 2000, fn ->
      with :ok <- existing_claim(config),
           {:ok, body} <-
             PrivateFiles.read_secret(Path.join(config.state_dir, "guest-#{guest.vm_id}.json")),
           {:ok, claim} <- JSON.decode(body),
           true <- claim == marker(guest),
           {:ok, interfaces} <- links(config),
           %{"ifalias" => link_alias, "flags" => flags} <-
             Enum.find(interfaces, &(&1["ifname"] == guest.tap)),
           true <- link_alias == marker(guest) and "UP" in flags,
           {:ok, program} <- FlowLabel.rules(config, guest, intent),
           {:ok, token} <- FlowLabel.token(config.host_id, intent) do
        current =
          with {:ok, bytes} <-
                 Command.in_namespace(config.namespace, :nft, [
                   "-j",
                   "list",
                   "table",
                   "inet",
                   guest.guard
                 ]),
               {:ok, document} <- JSON.decode(bytes),
               do: FlowLabel.current?(document, guest, token),
               else: (_ -> false)

        if current,
          do: :ok,
          else: rules(config, "#{guest.guard}-flow.nft", program, :namespace)
      else
        _ -> {:error, :network_identity_conflict}
      end
    end)
  end

  @doc "Caller must first confirm the VM's systemd unit and cgroup are stopped."
  # @cc [owner:ghuntley,label:assumption;recovery] detach-requires-empty-compute
  # Callers of detach/2 MUST first prove the VM unit and cgroup are stopped. detach/2 may remove
  # only the TAP matching this guest claim; an identity conflict must leave it untouched.
  @spec detach(Config.t(), Guest.t()) :: result()
  @spec detach(Config.t(), Guest.t(), OverallsProtocol.uuid() | nil) :: result()
  def detach(config, guest, vm_id \\ nil) do
    locked(config, fn ->
      with :ok <- existing_claim(config),
           {:ok, links} <- links(config) do
        case Enum.find(links, &(&1["ifname"] == guest.tap)) do
          nil ->
            with :ok <-
                   rules(
                     config,
                     "#{guest.guard}.nft",
                     "add table netdev #{guest.guard}\ndelete table netdev #{guest.guard}\n" <>
                       FlowLabel.clear(guest),
                     :namespace
                   ),
                 do: remove_guest_claim(config, guest)

          link ->
            if link["ifalias"] == marker(guest) do
              with :ok <- ns(config, :ip, ["link", "set", "dev", guest.tap, "down"]),
                   :ok <-
                     rules(
                       config,
                       "#{guest.guard}.nft",
                       "add table netdev #{guest.guard}\ndelete table netdev #{guest.guard}\n" <>
                         FlowLabel.clear(guest),
                       :namespace
                     ),
                   :ok <- ns(config, :ip, ["tuntap", "del", "dev", guest.tap, "mode", "tap"]),
                   :ok <- remove_guest_claim(config, guest) do
                network_detached(vm_id, guest)
              end
            else
              {:error, :network_identity_conflict}
            end
        end
      else
        _ -> {:error, :network_detach_failed}
      end
    end)
  end

  defp network_detached(nil, _guest), do: :ok

  defp network_detached(vm_id, guest) do
    Lilly.Events.emit("lilly.network_detached", vm_id: vm_id, placement_id: guest.vm_id)

    :ok
  end

  @doc "Remove only this empty owned namespace and its host rules; never a host-wide ruleset."
  # @cc [owner:ghuntley,label:security] network-cleanup-owned-empty-only
  # destroy/1 MUST remove only this host-owned empty namespace, veth pair and named nftables
  # tables; unknown devices or namespace processes must prevent cleanup, and unrelated host
  # firewall rules must remain intact.
  @spec destroy(Config.t()) :: result()
  def destroy(config) do
    locked(config, fn ->
      case File.lstat(Path.join(config.state_dir, "network.json")) do
        {:error, :enoent} ->
          absent(config)

        _ ->
          with :ok <- existing_claim(config),
               {:ok, namespaces} <- namespaces(),
               :ok <- empty_namespace(config, config.namespace in namespaces),
               :ok <- remove_root_link(config),
               :ok <- remove_namespace(config, config.namespace in namespaces),
               :ok <-
                 rules(
                   config,
                   "root.nft",
                   "add table inet #{config.tag}_filter\ndelete table inet #{config.tag}_filter\n" <>
                     "add table ip #{config.tag}_nat\ndelete table ip #{config.tag}_nat\n",
                   :root
                 ),
               :ok <- File.rm(Path.join(config.state_dir, "network.json")),
               :ok <- run(:sync, ["--", config.state_dir]),
               do: :ok,
               else: (_ -> {:error, :network_cleanup_unconfirmed})
      end
    end)
  end

  defp empty_namespace(_config, false), do: :ok

  defp empty_namespace(config, true) do
    with {:ok, body} <- Command.in_namespace(config.namespace, :ip, ["-d", "-j", "link", "show"]),
         {:ok, links} <- JSON.decode(body),
         true <- Enum.all?(links, &disposable_link?/1),
         {:ok, pids} <- Command.run(:ip, ["netns", "pids", config.namespace]),
         true <- String.trim(pids) == "",
         do: :ok
  end

  defp disposable_link?(%{"ifname" => name}) when name in ["lo", "uplink"], do: true

  defp disposable_link?(link) do
    # Loading a tunnel module creates inactive fallback devices in every netns.
    kinds = %{
      "gre0" => "gre",
      "gretap0" => "gretap",
      "erspan0" => "erspan",
      "tunl0" => "ipip",
      "sit0" => "sit",
      "ip6tnl0" => "ip6tnl",
      "ip6gre0" => "ip6gre"
    }

    kind = kinds[link["ifname"]]

    kind != nil and get_in(link, ["linkinfo", "info_kind"]) == kind and
      "UP" not in link["flags"] and
      Enum.all?(
        ["local", "remote"],
        &(get_in(link, ["linkinfo", "info_data", &1]) in [nil, "any", "0.0.0.0", "::"])
      )
  end

  defp remove_namespace(_config, false), do: :ok
  defp remove_namespace(config, true), do: run(:ip, ["netns", "delete", config.namespace])

  defp remove_root_link(config) do
    with {:ok, links} <- json(:ip, ["-j", "link", "show"]) do
      if Enum.any?(links, &(&1["ifname"] == config.uplink)) do
        with :ok <- verify_root_link(config), do: run(:ip, ["link", "delete", config.uplink])
      else
        :ok
      end
    end
  end

  defp absent(config) do
    with {:ok, namespaces} <- namespaces(),
         true <- config.namespace not in namespaces,
         {:ok, links} <- json(:ip, ["-j", "link", "show"]),
         true <- not Enum.any?(links, &(&1["ifname"] == config.uplink)),
         {:ok, tables} <- json(:nft, ["--json", "list", "tables"]),
         true <-
           not Enum.any?(
             tables["nftables"],
             &(get_in(&1, ["table", "name"]) in [config.tag <> "_filter", config.tag <> "_nat"])
           ),
         do: :ok,
         else: (_ -> {:error, :network_cleanup_unconfirmed})
  end

  # @cc [owner:ghuntley,label:concurrency;recovery] network-lock-bounded-wait
  # Every network-lock holder (attach, detach, label refresh, setup, destroy)
  # MUST wait a bounded two seconds for it. Periodic reconciles of every VM take
  # this host-wide lock, so a single non-waiting attempt starved relaunches
  # under load (a clone source deferred network_unavailable for minutes).
  # Contention MUST delay, never fail, an operation (ADR-0140).
  @spec locked(Config.t(), (-> result())) :: result()
  defp locked(config, fun), do: locked(config, 2000, fun)

  @spec locked(Config.t(), 0..2000, (-> result())) :: result()
  defp locked(config, retry_ms, fun) do
    with {:ok, %File.Stat{uid: 0}} <- Lilly.Host.Privilege.stat("/proc/self"),
         :ok <- PrivateFiles.directory(config.state_dir),
         {:ok, port} <- Lock.acquire(Path.join(config.state_dir, "network-lock"), retry_ms) do
      try do
        fun.()
      after
        Lock.release(port)
      end
    else
      _ -> {:error, :network_unavailable}
    end
  end

  defp identity(config),
    do: %{
      "version" => 1,
      "host_id" => config.host_id,
      "egress" => config.egress,
      "protected" => config.protected
    }

  defp claim(config) do
    case File.read(Path.join(config.state_dir, "network.json")) do
      {:error, :enoent} ->
        with {:ok, namespaces} <- namespaces(),
             true <- config.namespace not in namespaces,
             {:ok, links} <- json(:ip, ["-j", "link", "show"]),
             true <- not Enum.any?(links, &(&1["ifname"] == config.uplink)),
             {:ok, addresses} <- json(:ip, ["-j", "-4", "addr", "show"]),
             true <-
               not Enum.any?(addresses, fn interface ->
                 Enum.any?(
                   interface["addr_info"] || [],
                   &(&1["local"] in ~w(169.254.255.0 169.254.255.1 169.254.255.2 169.254.255.3))
                 )
               end),
             do:
               PrivateFiles.write(
                 config.state_dir,
                 "network.json",
                 JSON.encode!(identity(config))
               )

      {:ok, _} ->
        existing_claim(config)

      _ ->
        :error
    end
  end

  defp existing_claim(config) do
    with {:ok, body} <- PrivateFiles.read_secret(Path.join(config.state_dir, "network.json")),
         {:ok, value} <- JSON.decode(body),
         true <- value == identity(config),
         do: :ok
  end

  defp ensure_namespace(config) do
    with {:ok, namespaces} <- namespaces() do
      if config.namespace in namespaces,
        do: :ok,
        else: run(:ip, ["netns", "add", config.namespace])
    end
  end

  defp ensure_link(config) do
    with {:ok, root_links} <- json(:ip, ["-j", "link", "show"]) do
      created =
        if Enum.any?(root_links, &(&1["ifname"] == config.uplink)) do
          :ok
        else
          run(:ip, [
            "link",
            "add",
            config.uplink,
            "type",
            "veth",
            "peer",
            "name",
            "uplink",
            "netns",
            config.namespace
          ])
        end

      # Recover a crash between veth creation and alias assignment only when
      # the two interfaces are still the exact peer pair in our owned namespace.
      with :ok <- created,
           {:ok, [parent]} <- json(:ip, ["-j", "-d", "link", "show", "dev", config.uplink]),
           {:ok, peers} <- links(config),
           peer when is_map(peer) <- Enum.find(peers, &(&1["ifname"] == "uplink")),
           true <- get_in(parent, ["linkinfo", "info_kind"]) == "veth",
           true <-
             parent["link_index"] == peer["ifindex"] and peer["link_index"] == parent["ifindex"],
           true <- parent["ifalias"] in [nil, "", "lilly:" <> config.host_id],
           do:
             run(:ip, ["link", "set", "dev", config.uplink, "alias", "lilly:" <> config.host_id])
    end
  end

  defp verify_root_link(config) do
    with {:ok, [link]} <- json(:ip, ["-j", "link", "show", "dev", config.uplink]),
         true <- link["ifalias"] == "lilly:" <> config.host_id,
         do: :ok
  end

  defp configure_private_services(%Config{private_services: true} = config),
    do: ns(config, :ip, ["addr", "replace", "169.254.254.1/32", "dev", "lo"])

  defp configure_private_services(_), do: :ok

  # @cc [owner:ghuntley,label:security;recovery] router-namespace-source-validation
  # The router namespace MUST pin every IPv4 validation sysctl it depends on
  # instead of inheriting host values. In particular src_valid_mark MUST be 0:
  # with strict rp_filter, a host setting of 1 (Tailscale sets it on exit nodes)
  # makes reverse-path checks follow Brady's tproxy mark into its local-delivery
  # table, so every intercepted guest SYN is dropped as a local source.
  # arp_announce MUST be 2: replies from 169.254.254.1 otherwise solicit a guest
  # MAC with that source, and the TAP guard drops a guest ARP reply addressed
  # anywhere but its gateway. A memory-restored guest that never re-ARPs would
  # then stay unreachable until its own gateway entry expired.
  defp configure_link(config) do
    with :ok <-
           run(:sysctl, [
             "-qw",
             "net.ipv6.conf.#{config.uplink}.disable_ipv6=1",
             "net.ipv4.conf.#{config.uplink}.accept_source_route=0"
           ]),
         :ok <-
           ns(config, :sysctl, [
             "-qw",
             "net.ipv4.ip_forward=1",
             "net.ipv6.conf.all.disable_ipv6=1",
             "net.ipv6.conf.default.disable_ipv6=1",
             "net.ipv4.conf.all.accept_source_route=0",
             "net.ipv4.conf.default.accept_source_route=0",
             "net.ipv4.conf.all.accept_redirects=0",
             "net.ipv4.conf.default.accept_redirects=0",
             "net.ipv4.conf.all.send_redirects=0",
             "net.ipv4.conf.default.send_redirects=0",
             "net.ipv4.conf.all.rp_filter=1",
             "net.ipv4.conf.default.rp_filter=1",
             "net.ipv4.conf.all.src_valid_mark=0",
             "net.ipv4.conf.default.src_valid_mark=0",
             "net.ipv4.conf.all.arp_ignore=1",
             "net.ipv4.conf.default.arp_ignore=1",
             "net.ipv4.conf.all.arp_announce=2",
             "net.ipv4.conf.default.arp_announce=2"
           ]),
         :ok <- run(:ip, ["addr", "replace", "169.254.255.1/30", "dev", config.uplink]),
         :ok <- ns(config, :ip, ["addr", "replace", "169.254.255.2/30", "dev", "uplink"]),
         :ok <- ns(config, :ip, ["link", "set", "lo", "up"]),
         :ok <- run(:ip, ["link", "set", config.uplink, "up"]),
         :ok <- ns(config, :ip, ["link", "set", "uplink", "up"]),
         :ok <-
           ns(config, :ip, [
             "route",
             "replace",
             "default",
             "via",
             "169.254.255.1",
             "dev",
             "uplink"
           ]),
         do: :ok
  end

  defp install_routes(config, guest) do
    Enum.reduce_while(guest.addresses, :ok, fn address, :ok ->
      case ns(config, :ip, [
             "route",
             "replace",
             address <> "/32",
             "dev",
             guest.tap,
             "scope",
             "link"
           ]) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp available_route(config, guest) do
    Enum.reduce_while(guest.addresses, :ok, fn address, :ok ->
      with {:ok, body} <-
             Command.in_namespace(config.namespace, :ip, [
               "-j",
               "route",
               "show",
               "exact",
               address <> "/32"
             ]),
           {:ok, routes} <- JSON.decode(body),
           true <- Enum.all?(routes, &(&1["dev"] == guest.tap)) do
        {:cont, :ok}
      else
        _ -> {:halt, {:error, :network_identity_conflict}}
      end
    end)
  end

  defp ensure_tap(config, guest) do
    with {:ok, body} <- Command.in_namespace(config.namespace, :ip, ["-d", "-j", "link", "show"]),
         {:ok, links} <- JSON.decode(body) do
      result =
        case Enum.find(links, &(&1["ifname"] == guest.tap)) do
          nil ->
            ns(config, :ip, [
              "tuntap",
              "add",
              "dev",
              guest.tap,
              "mode",
              "tap",
              "user",
              Integer.to_string(guest.uid)
            ])

          link ->
            if link["ifalias"] in [nil, "", marker(guest)] and
                 get_in(link, ["linkinfo", "info_kind"]) == "tun" and
                 get_in(link, ["linkinfo", "info_data", "type"]) == "tap" and
                 get_in(link, ["linkinfo", "info_data", "user"]) == guest.uid,
               do: :ok,
               else: :error
        end

      # @cc [owner:ghuntley,label:recovery] tap-gateway-mac-before-up
      # Every created or adopted TAP MUST carry the guest's host-independent
      # gateway MAC before addressing and link-up. A kernel-random MAC breaks a
      # memory-restored guest's cached gateway neighbour after relocation.
      with :ok <- result,
           :ok <- ns(config, :ip, ["link", "set", "dev", guest.tap, "address", guest.gateway_mac]),
           :ok <- ns(config, :ip, ["link", "set", "dev", guest.tap, "alias", marker(guest)]),
           do: :ok
    end
  end

  defp marker(guest), do: "lilly:#{guest.vm_id}:#{Enum.join(guest.addresses, ",")}:#{guest.uid}"

  defp guest_claim(config, guest) do
    name = "guest-#{guest.vm_id}.json"

    case File.lstat(Path.join(config.state_dir, name)) do
      {:error, :enoent} ->
        with {:ok, links} <- links(config),
             true <- not Enum.any?(links, &(&1["ifname"] == guest.tap)),
             do: PrivateFiles.write(config.state_dir, name, JSON.encode!(marker(guest)))

      {:ok, _} ->
        with {:ok, body} <- PrivateFiles.read_secret(Path.join(config.state_dir, name)),
             {:ok, value} <- JSON.decode(body),
             true <- value == marker(guest),
             do: :ok

      _ ->
        :error
    end
  end

  defp remove_guest_claim(config, guest) do
    case File.rm(Path.join(config.state_dir, "guest-#{guest.vm_id}.json")) do
      :ok -> run(:sync, ["--", config.state_dir])
      {:error, :enoent} -> :ok
      _ -> :error
    end
  end

  defp links(config) do
    with {:ok, body} <- Command.in_namespace(config.namespace, :ip, ["-j", "link", "show"]),
         do: JSON.decode(body)
  end

  defp rules(config, filename, contents, scope) do
    with :ok <- PrivateFiles.write(config.state_dir, filename, contents) do
      args = ["--file", Path.join(config.state_dir, filename)]
      if scope == :root, do: run(:nft, args), else: ns(config, :nft, args)
    end
  end

  defp run(tool, args) do
    case Command.run(tool, args) do
      {:ok, _} -> :ok
      error -> error
    end
  end

  defp ns(config, tool, args) do
    case Command.in_namespace(config.namespace, tool, args) do
      {:ok, _} -> :ok
      error -> error
    end
  end

  defp json(tool, args) do
    with {:ok, body} <- Command.run(tool, args), do: JSON.decode(body)
  end

  defp namespaces do
    # ip netns list emits no JSON at all for an empty directory, even with -j.
    with {:ok, body} <- Command.run(:ip, ["netns", "list"]) do
      {:ok, body |> String.split("\n", trim: true) |> Enum.map(&(String.split(&1) |> hd()))}
    end
  end
end
