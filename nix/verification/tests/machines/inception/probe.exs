defmodule InceptionFixture do
  @moduledoc false
  alias Lilly.Host.{Image, Pool, PrivateFiles, ZFS}
  alias Lilly.Terminal.Vsock
  alias Lilly.VM.{Boot, Config, Driver, Observation, Spec}

  @type terminal :: %{socket: Vsock.socket(), control: Vsock.socket(), session_id: pos_integer()}

  def run do
    step = fn label ->
      File.write(
        "/run/inception-test/probe-steps.log",
        label <> " at " <> Integer.to_string(System.system_time(:second)) <> "\n",
        [:append]
      )
    end

    step.("fixture entered")
    host = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
    pool_id = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"
    # Independently enrolled identities must never reuse another host's durable
    # pool ownership. The managed scenario owns /pool; direct cases own this pool.
    pool_path =
      if System.fetch_env!("INCEPTION_ACTION") == "outer-request",
        do: "/pool",
        else: "/direct-pool"

    :ok = File.write("/dev/console", "inception fixture: inspecting pool\n")
    {:ok, identity} = ZFS.inspect_path(pool_path)
    step.("pool inspected")

    {:ok, pool} =
      Pool.new(pool_id, pool_path, identity.filesystem_id,
        storage: OverallsProtocol.Storage.encode(identity.storage),
        host_id: host
      )

    step.("pool built")
    :ok = File.write("/dev/console", "inception fixture: verifying image\n")
    # The configured image is an immutable Nix store output. Use the same
    # structural authority as Inception's uncached production launch path;
    # hashing its sparse 64 GiB root for every probe makes the native test take
    # tens of minutes before it reaches any lifecycle assertion.
    {:ok, image} = Image.load_immutable(System.fetch_env!("INCEPTION_IMAGE"))
    step.("image loaded")
    :ok = File.write("/dev/console", "inception fixture: image verified\n")

    {:ok, spec} =
      Spec.new(%{
        id: "dddddddd-dddd-4ddd-8ddd-000000000140",
        image_id: image.id,
        pool_id: pool_id,
        profile: :inception,
        slot: 142,
        vcpu: 16,
        memory_bytes: 32 * 1024 ** 3,
        disk_bytes: 64 * 1024 ** 3
      })

    tools = System.fetch_env!("INCEPTION_TOOLS") |> File.read!() |> JSON.decode!()
    {:ok, network} = Lilly.Network.Config.new(host, "eth1", [], "/var/lib/lilly/network")

    :ok =
      PrivateFiles.write(
        "/run/inception-test",
        "smtp.json",
        JSON.encode!(%{
          "version" => 1,
          "host" => "smtp.example.test",
          "port" => 587,
          "username" => "fixture",
          "password" => "synthetic-inception-fixture",
          "from" => "dev@example.test",
          "tls" => "starttls"
        })
      )

    {:ok, config} =
      Config.new(%{
        state_dir: "/var/lib/lilly/vms",
        network: network,
        firecracker: tools["firecracker"],
        jailer: tools["jailer"],
        unshare: tools["unshare"],
        inception_smtp_file: "/run/inception-test/smtp.json",
        inception_image_id: image.id,
        inception_proof_file: "/run/lilly-inception/proof.json",
        inception_probe_id: System.fetch_env!("INCEPTION_PROBE_IMAGE")
      })

    generation = System.fetch_env!("INCEPTION_GENERATION") |> String.to_integer()
    options = [execution_epoch: 1, generation: generation]
    step.("config prepared")

    {config, pool, spec, options} =
      if System.get_env("INCEPTION_MANAGED") == "1" do
        {:ok, control} = Lilly.Control.Config.load("/run/inception-outer/lilly.json")
        instance = System.get_env("INCEPTION_INSTANCE", "1")
        true = instance in ["1", "2"]
        command_file = if instance == "2", do: "two-command.json", else: "command.json"

        {:ok, command} =
          Path.join("/run/inception-outer", command_file)
          |> File.read!()
          |> JSON.decode!()
          |> OverallsProtocol.Execution.command()

        {:ok, managed} =
          command
          |> Map.take([
            :image_id,
            :pool_id,
            :profile,
            :slot,
            :vcpu,
            :memory_bytes,
            :disk_bytes,
            :git_identity
          ])
          |> Map.put(:id, command.placement_id)
          |> Spec.new()

        {control.execution, Enum.find(control.pools, &(&1.id == command.pool_id)), managed,
         [execution_epoch: command.execution_epoch, generation: command.generation]}
      else
        {config, pool, spec, options}
      end

    case System.fetch_env!("INCEPTION_ACTION") do
      "outer-request" ->
        # The direct-driver fixture used a different host identity. Remove its
        # now-empty owned router before enrolling the real control-plane host.
        :ok = Lilly.Network.destroy(network)
        {:ok, machine} = Lilly.Host.Identity.read()

        :ok =
          PrivateFiles.write(
            "/run/inception-outer",
            "request.json",
            JSON.encode!(%{
              version: 3,
              name: "outer-native",
              architecture: "x86_64",
              machine_id: machine,
              overhead_cores: 0,
              overhead_memory_bytes: 0,
              credential_ttl_seconds: 3600,
              pools: [
                %{
                  name: "guests",
                  storage: OverallsProtocol.Storage.encode(identity.storage),
                  overhead_bytes: 0
                }
              ]
            })
          )

      "network-restore" ->
        # The driver stops the managed Lilly after proving both disks deleted.
        # Both fixture identities share this state directory; hand it back only
        # through the production owned-empty cleanup, never by deleting claims.
        {:ok, control} = Lilly.Control.Config.load("/run/inception-outer/lilly.json")
        :ok = Lilly.Network.destroy(control.execution.network)
        :ok = Lilly.Network.setup(network)

      "deleted" ->
        false = Observation.running?(config, pool, spec)
        false = File.exists?(Lilly.VM.Disk.path(pool, spec))
        false = File.exists?(Path.join(Path.dirname(Lilly.VM.Disk.path(pool, spec)), "data.raw"))

      "reject-proof" ->
        step.("reject-proof branch entered")
        {:ok, original} = PrivateFiles.read_secret(config.inception_proof_file)
        proof = JSON.decode!(original)

        try do
          for {key, value} <- [
                {"boot_id", "ffffffff-ffff-4fff-8fff-ffffffffffff"},
                {"image_id", "sha256:" <> String.duplicate("0", 64)},
                {"probe_id", "/nix/store/other-probe"},
                {"firecracker", "/other-vmm"}
              ] do
            File.write(
              "/run/inception-test/probe-steps.log",
              "tampering #{key} at #{System.system_time(:second)}\n",
              [:append]
            )

            :ok =
              PrivateFiles.write(
                "/run/lilly-inception",
                "proof.json",
                JSON.encode!(Map.put(proof, key, value))
              )

            File.write(
              "/run/inception-test/probe-steps.log",
              "image_id checked at #{System.system_time(:second)}\n",
              [:append]
            )

            nil = Lilly.Host.InceptionProof.image_id(config)

            File.write(
              "/run/inception-test/probe-steps.log",
              "driver start at #{System.system_time(:second)}\n",
              [:append]
            )

            {:error, :inception_credentials_unavailable} =
              Driver.start(config, pool, image, spec, options)

            File.write(
              "/run/inception-test/probe-steps.log",
              "driver returned at #{System.system_time(:second)}\n",
              [:append]
            )

            false = File.exists?(Lilly.VM.Disk.path(pool, spec))
          end
        after
          File.write(
            "/run/inception-test/probe-steps.log",
            "loop exited at #{System.system_time(:second)}\n",
            [:append]
          )

          :ok = PrivateFiles.write("/run/lilly-inception", "proof.json", original)
        end

        true = Lilly.Host.InceptionProof.image_id(config) == image.id

      "browser-token" ->
        instance = System.fetch_env!("INCEPTION_INSTANCE")
        true = instance in ["1", "2"]
        copy_fixture(
          config,
          spec,
          "/etc/inception-inner-browser.exs",
          "/root/inception-inner-browser.exs"
        )

        operator =
          "INCEPTION_BROWSER_INSTANCE=#{instance} python3 $(jq -r .bootstrap /etc/inception-public.json) exec /etc/inception-public.json $(jq -r .marshall_release /etc/inception-public.json)/bin/marshall eval 'Code.eval_file(\"/root/inception-inner-browser.exs\")'"

        :pass = console(config, spec, operator, 60_000)
        {:ok, bytes} = console_private(config, spec, 10_000)
        {:ok, %{"token" => token} = value} = JSON.decode(bytes)
        true = map_size(value) == 1 and is_binary(token) and
          byte_size(token) in 32..4096 and Regex.match?(~r/\A[!-~]+\z/, token)
        :ok = PrivateFiles.write("/run/inception-test", "browser-#{instance}.json", bytes)

      "private-services" ->
        instance = System.fetch_env!("INCEPTION_INSTANCE")
        true = instance in ["1", "2"]

        copy_fixture(
          config,
          spec,
          "/etc/inception-provider-configure.py",
          "/root/inception-provider-configure.py"
        )

        copy_fixture(
          config,
          spec,
          "/run/inception-public-issuer-ca.pem",
          "/root/inception-provider-ca.pem"
        )

        :pass =
          console(
            config,
            spec,
            "python3 /root/inception-provider-configure.py #{instance}",
            360_000
          )

      "wildcard" ->
        copy_fixture(config, spec, "/etc/inception-wildcard-probe.py", "/root/inception-wildcard-probe.py")
        await(fn -> console(config, spec, "python3 /root/inception-wildcard-probe.py --record", 5000) == :pass end,
              deadline(300_000))
        :pass = console(config, spec, "systemctl restart marshall-inception.service audi.service", 120_000)
        await(fn -> console(config, spec, "python3 /root/inception-wildcard-probe.py --verify", 5000) == :pass end,
              deadline(120_000))

      "inner-" <> action when action in ["create", "stop", "start", "delete"] ->
        for {source, target} <- [
              {"/etc/inception-inner.exs", "/root/inception-inner.exs"},
              {"/etc/inception-inner-physical.exs", "/root/inception-inner-physical.exs"}
            ] do
          copy_fixture(config, spec, source, target)
        end

        operator =
          "INCEPTION_NATIVE_ACTION=#{action} python3 $(jq -r .bootstrap /etc/inception-public.json) exec /etc/inception-public.json $(jq -r .marshall_release /etc/inception-public.json)/bin/marshall eval 'Code.eval_file(\"/root/inception-inner.exs\")'"

        :pass = console(config, spec, operator, 900_000)

        physical =
          "INCEPTION_NATIVE_ACTION=#{action} python3 $(jq -r .bootstrap /etc/inception-public.json) exec /etc/inception-public.json $(jq -r .lilly_release /etc/inception-public.json)/bin/lilly eval 'Code.eval_file(\"/root/inception-inner-physical.exs\")'"

        :pass = console(config, spec, physical, 600_000)

      "start" ->
        :ok = Lilly.Network.setup(network)
        :ok = retry(fn -> Driver.start(config, pool, image, spec, options) end, deadline(120_000))
        await(fn -> Observation.running?(config, pool, spec) end, deadline(30_000))
        # Direct-driver cases have no outer Marshall poller. Deliver their
        # isolated fixture namespace through the actual owned vsock exchange.
        namespace = %{
          label: OverallsProtocol.IngressName.label("fixture", spec.id),
          zone: "apps.inception.test",
          generation: 1,
          public: "/run/inception-public-settings.json" |> File.read!() |> JSON.decode!()
        }

        await(
          fn ->
            match?({:ok, _}, Driver.inception_publication(config, pool, spec, namespace, options))
          end,
          deadline(120_000)
        )

        task =
          Task.async(fn ->
            Driver.ready(config, pool, spec, Keyword.put(options, :timeout, 2_400_000))
          end)

        case await_ready(task, config, spec) do
          :ok ->
            :ok

          _ ->
            diagnose_marshall(config, spec)

            for unit <-
                  ~w(inception-identity inception-credentials inception-storage postgresql postgresql-setup inception-environment inception-database inception-migrate inception-enrollment marshall-inception lilly inception-enable) do
              IO.puts(
                "#{unit}: #{console(config, spec, "systemctl is-active --quiet #{unit}.service", 5000)}"
              )
            end

            raise "Inception stack not ready; credential and terminal bytes withheld"
        end

      "verify" ->
        # Reconciliation can observe the surviving VMM before inner services
        # finish booting. Require the actual boot-bound core readiness response;
        # a process-running observation must not stand in for enrollment readiness.
        # The native fixture has a fifteen-minute command envelope.  Keep the
        # readiness wait below that envelope so a failed nested boot reaches
        # diagnose_marshall/2 instead of being killed by the outer timeout with
        # no category-only evidence.
        ready_result = Driver.ready(config, pool, spec, Keyword.put(options, :timeout, 60_000))
        case ready_result do
          :ok ->
            :ok

          {:error, reason} when is_atom(reason) ->
            IO.puts("Core readiness result: #{reason}")
            diagnose_marshall(config, spec)

            for unit <- ~w(inception-enrollment inception-enable lilly marshall-inception) do
              IO.puts(
                "Core #{unit}: #{console(config, spec, "systemctl is-active --quiet #{unit}.service", 3000)}"
              )
            end

            raise "Inner core readiness unavailable; terminal and credentials withheld"

          _ ->
            IO.puts("Core readiness result: unavailable")
            raise "Inner core readiness unavailable; terminal and credentials withheld"
        end

        # The development checkout is deliberately independent of gateway
        # certificate issuance. Assert it immediately after core readiness so
        # a later Ziggy/DNS retry cannot mask the capability that lets an
        # operator develop Overalls inside an Inception guest.
        # The machine fixture's isolated provider node is the reviewed public
        # egress router. Keep the guest's production public resolver address
        # after the private-DNS unit has installed its ~internal route. The
        # fixture owns that public /32 locally and forwards DNS to its
        # isolated dnsmasq instance, so no real Internet dependency is added.
        :pass =
          console(
            config,
            spec,
            # The private resolver may have cached a negative answer before
            # the fixture's public route is installed. Flush that cache before
            # switching the guest to the isolated public resolver path.
            "resolvectl flush-caches && resolvectl reset-server-features && resolvectl dns eth0 1.1.1.1 9.9.9.9 && resolvectl default-route eth0 yes && systemctl restart inception-source.service",
            5000
          )

        # The workload contract requires the canonical public origin. The
        # fixture maps that hostname to its isolated HTTPS mirror, but must not
        # weaken the assertion by accepting a test-only alternate URL.
        expected_source = "https://github.com/ghuntley/overalls"

        source_https_check =
          "GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null git ls-remote " <>
            expected_source <> " >/dev/null 2>&1"
        source_origin_check =
          "test -d /workspace/overalls/.git && test \"$(GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null git -C /workspace/overalls config --local --get remote.origin.url)\" = " <>
            expected_source <>
            " && runuser -u nobody -- test -w /workspace/overalls/README.md"

        try do
          await(
            fn ->
              console(
                config,
                spec,
                # The checkout is the durable product requirement.  The
                # profile-owned source unit may be restarting its bounded Git
                # retry loop while an already-published checkout remains
                # usable, so do not make a transient systemd state gate the
                # assertion.
                "test -d /workspace/overalls/.git",
                5000
              ) == :pass
            end,
            deadline(600_000)
          )
        rescue
          error in RuntimeError ->
            # Keep a failed native run actionable without returning Git output,
            # URLs, or terminal bytes.  These predicates distinguish a source
            # retry from a published checkout whose unit is merely restarting.
            for {name, command} <- [
                  {"source active", "systemctl is-active --quiet inception-source.service"},
                  {"source failed", "systemctl is-failed --quiet inception-source.service"},
                  {"source result", "test \"$(systemctl show -p Result --value inception-source.service)\" = success"},
                  {"source retries", "test \"$(systemctl show -p NRestarts --value inception-source.service)\" != 0"},
                  {"checkout directory", "test -d /workspace/overalls"},
                  {"checkout Git metadata", "test -d /workspace/overalls/.git"},
                  {"source attempt timed out", "grep -q '^timeout$' /run/inception/source-status"},
                  {"source command failed", "grep -q '^failed$' /run/inception/source-status"},
                  {"source publication succeeded", "grep -q '^success$' /run/inception/source-status"},
                  {"source trust bundle", "test -s /etc/ssl/certs/ca-bundle.crt"},
                  {"source route", "ip route get 1.1.1.1 >/dev/null 2>&1"},
                  {"source DNS", "python3 -c 'import socket; socket.getaddrinfo(\"github.com\", 443)' >/dev/null 2>&1"},
                  {"source resolver", "resolvectl status >/dev/null 2>&1"},
                  {"source HTTPS", source_https_check}
                ] do
              IO.puts("Inception source #{name}: #{console(config, spec, command, 3000)}")
            end

            reraise(error, __STACKTRACE__)
        end

        :pass = console(
          config,
          spec,
          source_origin_check,
          5000
        )
        # Return the guest to its production split-DNS policy before gateway
        # and private-service assertions. The fixture-only public resolver
        # selection is needed solely for the canonical GitHub bootstrap above.
        :pass =
          console(
            config,
            spec,
            "resolvectl dns eth0 169.254.254.1 && resolvectl default-route eth0 no",
            5000
          )

        try do
          await(
            fn ->
              console(
                config,
                spec,
                "systemctl is-active --quiet porsche.service audi.service audi-dns.service inception-publication.service && jq -e '(.porsche_host_key | startswith(\"ssh-ed25519 \") ) and (.audi_host_key | startswith(\"ssh-ed25519 \") )' /run/inception/publication.json",
                5000
              ) == :pass
            end,
            # Gateway startup includes the independently retried host
            # certificate publication.  A healthy nested guest may therefore
            # take several minutes after core readiness; keep waiting within
            # the outer probe's bounded 945 second command deadline instead
            # of treating that expected recovery window as a failed guest.
            # Leave a small margin for the probe's 945-second outer command
            # timeout after the nested guest has spent several minutes
            # obtaining its independently retried gateway certificates.
            deadline(840_000)
          )
        rescue
          RuntimeError ->
            diagnose_ingress(config, spec)
            raise "Inner ingress publication unavailable; credential and terminal bytes withheld"
        end

        copy_fixture(config, spec, "/etc/inception-dns-probe.py", "/root/inception-dns-probe.py")

        copy_fixture(
          config,
          spec,
          "/etc/inception-inner-ziggy.exs",
          "/root/inception-inner-ziggy.exs"
        )

        ziggy_probe =
          "python3 $(jq -r .bootstrap /etc/inception-public.json) exec /etc/inception-public.json $(jq -r .marshall_release /etc/inception-public.json)/bin/marshall eval 'Code.eval_file(\"/root/inception-inner-ziggy.exs\")'"

        # Enrollment enabling and the first independent Ziggy credential
        # transaction share the inner Marshall database with the gateway
        # certificate workers. Retry the fixed authority probe while that
        # transaction converges; a single 30-second console attempt can race
        # an otherwise healthy post-readiness stack and would prevent the
        # checkout assertions below from running.
        await(
          fn -> console(config, spec, ziggy_probe, 10_000) == :pass end,
          deadline(180_000)
        )

        await(
          fn -> console(config, spec, "python3 /root/inception-dns-probe.py", 5000) == :pass end,
          deadline(30_000)
        )

        # Preserve every physical assertion, but report only its fixed name and
        # pass/fail status. A combined shell condition hid which invariant failed.
        checks = [
          {"nested KVM device", "test -c /dev/kvm"},
          {"data disk size", "test $(blockdev --getsize64 /dev/vdb) = 274877906944"},
          {"inner pool quota", "test $(zfs get -Hpo value quota inception/lilly) = 257698037760"},
          {"developer repository",
           "test -d /workspace/overalls/.git && test \"$(GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null git -C /workspace/overalls config --local --get remote.origin.url)\" = " <>
             expected_source},
          {"developer repository writable",
           "runuser -u nobody -- test -w /workspace/overalls/README.md"},
          {"Git identity system include",
           "grep -qF '/run/overalls-workspace/git-identity/gitconfig' /etc/gitconfig"},
          {"Git identity runtime include",
           "test -f /run/overalls-workspace/git-identity/gitconfig && test $(stat -c '%a' /run/overalls-workspace/git-identity/gitconfig) = 644"},
          {"Git identity effective",
           "test \"$(git config --includes --get user.name)\" = Overalls && test \"$(git config --includes --get user.email)\" = noreply@overalls.dev"},
          {"inner host credential", "test -s /var/lib/inception/lilly-credential.json"},
          {"inner enrollment readiness", "systemctl is-active --quiet inception-enable.service"},
          {"private PKI active", "systemctl is-active --quiet inception-private-pki.service"},
          {"private issuer active", "systemctl is-active --quiet audi-private-issuer.service"},
          {"independent private issuer",
           "test -S /run/audi-private-issuer/issuer.sock && test -s /run/inception-public/private-root.pem"},
          {"private issuer recovery-key exclusion",
           "test -s /var/lib/inception/private-pki/root.key && test -s /run/audi-private-issuer/credentials/issuer.key && test ! -e /run/audi-private-issuer/credentials/root.key && test ! -e /run/credentials/audi-private-issuer.service/root.key"}
        ]

        results =
          Enum.map(checks, fn {name, command} ->
            result = console(config, spec, command, 5000)
            IO.puts("Inception physical check #{name}: #{result}")
            result
          end)

        if not Enum.all?(results, &(&1 == :pass)),
          do: raise("Inception physical verification failed; terminal and credentials withheld")

      "diagnose-core" ->
        # Capture only fixed status predicates before the production readiness
        # deadline stops an unsuccessful guest; never emit journal/console data.
        for {name, command} <- [
              {"image activating",
               "test $(systemctl show -p ActiveState --value inception-image.service) = activating"},
              {"guest uptime thirty minutes", "test $(cut -d. -f1 /proc/uptime) -ge 1800"}
            ] do
          IO.puts("Core #{name}: #{console(config, spec, command, 3000)}")
        end

        for unit <-
              ~w(inception-identity inception-credentials lilly-flush inception-ingress inception-namespace inception-private-pki inception-image inception-storage postgresql inception-database inception-environment inception-migrate inception-enrollment marshall-inception lilly inception-enable) do
          for state <- ["active", "failed"] do
            result = console(config, spec, "systemctl is-#{state} --quiet #{unit}.service", 3000)
            IO.puts("Core #{unit} #{state}: #{result}")
          end
        end

        # Classify the immutable seed registration without returning its
        # journal or any command output. The production path links the
        # prebuilt seed and delivers this instance's private root through
        # Lilly's authenticated trust channel; it no longer performs a
        # multi-gigabyte Nix rebuild inside the nested guest.
        for {name, command} <- [
              {"root filesystem resized", "test $(findmnt -bnro SIZE /) -ge 60000000000"},
              {"root filesystem free space",
               "test $(df -B1 --output=avail / | tail -1) -ge 4000000000"},
              {"public root present", "test -s /run/inception-public/private-root.pem"},
              {"seed image link",
               "test -L /var/lib/inception/guest-image && test -s /var/lib/inception/guest-image/manifest.json"},
              {"seed image store path",
               "case \"$(readlink /var/lib/inception/guest-image)\" in /nix/store/*) :;; *) exit 1;; esac"},
              {"default image identity", "test -s /run/inception/default-image-id"},
              {"private trust configured",
               "grep -qF /run/inception-public/private-root.pem /var/lib/inception/lilly.json"}
            ] do
          IO.puts("Core image #{name}: #{console(config, spec, command, 3000)}")
        end

      "diagnose-public" ->
        # Only fixed predicates leave the console; never disclose ACME output,
        # account files, certificate keys, terminal bytes or challenge values.
        # The driver discards stdout from successful diagnostic commands. Emit
        # these closed status values to the outer console so failures retain
        # useful evidence in the native run log.
        for unit <-
              ~w(inception-control-certificate inception-control-proxy inception-publication audi) do
          result = console(config, spec, "systemctl is-active --quiet #{unit}.service", 3000)
          IO.puts("Public #{unit} active: #{result}")
        end

        for {name, command} <- [
              {"control job", "test -s /run/inception-control/job.json"},
              {"job proofs", "jq -e '.proofs | length > 0' /run/inception-control/job.json"},
              {"control heartbeat", "test -s /run/inception/control-publication.json"},
              {"heartbeat proofs",
               "jq -e '.proofs | length > 0' /run/inception/control-publication.json"},
              {"published control proofs",
               "jq -e '.records[] | select(.label == \"control\") | .proofs | length > 0' /run/inception/publication.json"},
              {"published control ready",
               "jq -e '.records[] | select(.label == \"control\") | .ready == true' /run/inception/publication.json"},
              {"validated certificate", "test -s /var/lib/inception-control-proxy/full.pem"},
              {"issuer key path",
               "h=$(cat /run/inception/public-host) && test -f /var/lib/inception-control/acme/certificates/$h.key"},
              {"issuer certificate path",
               "h=$(cat /run/inception/public-host) && test -f /var/lib/inception-control/acme/certificates/$h.crt"},
              {"certificate rejection",
               "journalctl -u inception-control-certificate.service --no-pager -o cat | grep -qF inception.control_certificate_rejected"},
              {"certificate rejection stage",
               "test -s /run/inception-control/rejection-stage && printf 'stage=' && cat /run/inception-control/rejection-stage"},
              {"rejection at material", "grep -qx material /run/inception-control/rejection-stage"},
              {"rejection at process", "grep -qx process /run/inception-control/rejection-stage"},
              {"issuer process category timeout",
               "grep -qx timeout /run/inception-control/process-category"},
              {"issuer process category hook",
               "grep -qx hook /run/inception-control/process-category"},
              {"issuer process category filesystem",
               "grep -qx filesystem /run/inception-control/process-category"},
              {"issuer process category transport http",
               "grep -qx transport_http /run/inception-control/process-category"},
              {"issuer process category transport verify",
               "grep -qx transport_verify /run/inception-control/process-category"},
              {"issuer process category transport parse",
               "grep -qx transport_parse /run/inception-control/process-category"},
              {"issuer process category network",
               "grep -qx network /run/inception-control/process-category"},
              {"issuer process category acme",
               "grep -qx acme /run/inception-control/process-category"},
              {"issuer process category unknown",
               "grep -qx unknown /run/inception-control/process-category"},
              {"issuer process category success",
               "grep -qx success /run/inception-control/process-category"},
              {"rejection at validation", "grep -qx validate /run/inception-control/rejection-stage"},
              {"rejection at install", "grep -qx install /run/inception-control/rejection-stage"},
              {"rejection at service", "grep -qx service /run/inception-control/rejection-stage"},
              {"worker crash",
               "systemctl show -p NRestarts --value inception-control-certificate.service | grep -qv '^0$'"}
            ] do
          IO.puts("Public #{name}: #{console(config, spec, command, 3000)}")
        end

      "storage-refusal" ->
        :pass =
          console(
            config,
            spec,
            "umask 077; cp -p /var/lib/inception/storage.json /root/storage-original.json && jq '.pool_guid = \"0\"' /root/storage-original.json > /var/lib/inception/storage.json && ! python3 $(dirname $(jq -r .bootstrap /etc/inception-public.json))/storage.py",
            30_000
          )

        :pass =
          console(
            config,
            spec,
            "test $(zpool get -Hpo value guid inception) = $(jq -r .pool_guid /root/storage-original.json) && cp -p /root/storage-original.json /var/lib/inception/storage.json && python3 $(dirname $(jq -r .bootstrap /etc/inception-public.json))/storage.py",
            30_000
          )

      "remember" ->
        :pass =
          console(
            config,
            spec,
            "umask 077; sha256sum /var/lib/inception/identity.json /var/lib/inception/storage.json /var/lib/inception/lilly-credential.json > /root/inception-state.sha256 && printf developer-edit > /workspace/overalls/developer-edit && sync",
            30_000
          )

      "rotate" ->
        {:ok, bundle} = Lilly.VM.Credentials.load(config.inception_smtp_file)

        :ok =
          PrivateFiles.write(
            "/run/inception-test",
            "smtp.json",
            JSON.encode!(Map.put(bundle, "password", "synthetic-rotated-inception-fixture"))
          )

        :ok = Driver.configure(config, pool, spec, options)

        :pass =
          console(
            config,
            spec,
            "test $(jq -r .password /run/inception/smtp.json) = synthetic-rotated-inception-fixture && sha256sum -c /root/inception-state.sha256",
            30_000
          )

        :ok = Driver.ready(config, pool, spec, Keyword.put(options, :timeout, 120_000))

      "retained" ->
        :pass =
          console(
            config,
            spec,
            "sha256sum -c /root/inception-state.sha256 && test $(cat /workspace/overalls/developer-edit) = developer-edit",
            30_000
          )

      "stop" ->
        :ok = retry(fn -> Driver.stop(config, pool, spec, options) end, deadline(90_000))

      "delete" ->
        :ok = retry(fn -> Driver.delete(config, pool, spec, options) end, deadline(90_000))
    end

    :ok
  end

  # @cc [owner:ghuntley,label:verification] inception-fixture-bounded-copy
  # Fixture scripts MUST cross the terminal in bounded acknowledged chunks.
  # Failed or uncertain writes MUST abort without replay. Only fixed image-owned
  # source/destination paths may call this helper.
  defp copy_fixture(config, spec, source, target) do
    :pass = console(config, spec, "umask 077; : > #{target}.base64", 5000)

    source
    |> File.read!()
    |> Base.encode64()
    |> String.codepoints()
    |> Enum.chunk_every(768)
    |> Enum.each(fn chunk ->
      :pass = console(config, spec, "printf %s '#{Enum.join(chunk)}' >> #{target}.base64", 5000)
    end)

    :pass =
      console(config, spec, "base64 -d #{target}.base64 > #{target} && rm #{target}.base64", 5000)
  end

  # @cc [owner:ghuntley,label:security;verification] inception-fixture-console-redaction
  # Fixed fixture commands MUST yield only an unforgeable result marker. Terminal
  # bytes, environment and credential files MUST NOT enter fixture diagnostics.
  defp console(config, spec, command, timeout) do
    case connect_terminal(config, spec, deadline(min(timeout, 10_000))) do
      {:ok, terminal} ->
        try do
          marker = "INCEPTION_" <> Base.encode16(:crypto.strong_rand_bytes(12))

          :ok =
            Vsock.write(
              terminal.socket,
              "\nif (#{command}) >/dev/null 2>&1; then printf '\\n#{marker}:pass\\n'; else printf '\\n#{marker}:fail\\n'; fi\n"
            )

          receive_marker(terminal.socket, marker, deadline(timeout), "")
        after
          close_terminal(terminal)
        end

      _ ->
        :unavailable
    end
  end

  # @cc [owner:ghuntley,label:security;verification] inception-fixture-private-browser-token
  # A guest magic-link token MUST cross the terminal only inside bounded random
  # markers, then pass a closed JSON schema before mode-0600 storage. Terminal
  # bytes and token contents MUST never enter fixture output or diagnostics.
  @spec console_private(Config.t(), Spec.t(), pos_integer()) ::
          {:ok, binary()} | :unavailable
  defp console_private(config, spec, timeout) do
    case connect_terminal(config, spec, deadline(min(timeout, 10_000))) do
      {:ok, terminal} ->
        try do
          marker = "INCEPTION_" <> Base.encode16(:crypto.strong_rand_bytes(12))
          command =
            "printf '\\n#{marker}:begin\\n'; base64 -w0 /root/inception-browser-token.json; printf '\\n#{marker}:end\\n'"
          :ok = Vsock.write(terminal.socket, "\n(#{command}) 2>/dev/null\n")
          receive_private(terminal.socket, marker, deadline(timeout), "")
        after
          close_terminal(terminal)
        end

      _ ->
        :unavailable
    end
  end

  @spec receive_private(Vsock.socket(), binary(), integer(), binary()) ::
          {:ok, binary()} | :unavailable
  defp receive_private(socket, marker, until, tail) do
    if System.monotonic_time(:millisecond) >= until do
      :unavailable
    else
      case :gen_tcp.recv(socket, 0, 1000) do
        {:ok, bytes} ->
          body = :binary.replace(tail <> bytes, "\r", "", [:global])
          begin_marker = "\n#{marker}:begin\n"
          end_marker = "\n#{marker}:end\n"

          cond do
            byte_size(body) > 8192 ->
              :unavailable

            :binary.match(body, end_marker) == :nomatch ->
              receive_private(socket, marker, until, body)

            true ->
              with {begin_at, _} <- :binary.match(body, begin_marker),
                   {end_at, _} <- :binary.match(body, end_marker),
                   data_at = begin_at + byte_size(begin_marker),
                   true <- end_at > data_at,
                   encoded = binary_part(body, data_at, end_at - data_at),
                   true <- byte_size(encoded) <= 4096,
                   {:ok, decoded} <- Base.decode64(encoded) do
                {:ok, decoded}
              else
                _ -> :unavailable
              end
          end

        {:error, :timeout} ->
          receive_private(socket, marker, until, tail)

        _ ->
          :unavailable
      end
    end
  end

  defp receive_marker(socket, marker, until, tail) do
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

              receive_marker(
                socket,
                marker,
                until,
                binary_part(body, byte_size(body) - count, count)
              )
          end

        {:error, :timeout} ->
          receive_marker(socket, marker, until, tail)

        _ ->
          :unavailable
      end
    end
  end

  # @cc [owner:ghuntley,label:verification;security] inception-fixture-terminal-current-boot
  # Guest assertions MUST authenticate terminald with the persisted current boot
  # identity and an isolated root PTY. The fixture MUST retire that PTY and MUST
  # NOT print authentication material or terminal bytes.
  @spec connect_terminal(Config.t(), Spec.t(), integer()) ::
          {:ok, terminal()} | {:error, :terminal_unavailable}
  defp connect_terminal(config, spec, until) do
    directory = Path.join(config.state_dir, spec.id)

    result =
      with {:ok, intent} <- Lilly.VM.Intent.read(directory),
           {:ok, boot} <-
             Boot.current(directory, spec.id, {intent.execution_epoch, intent.generation}),
           {:ok, bytes} <- PrivateFiles.read_secret(Path.join(directory, "vm.json")),
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

  defp retry(fun, until) do
    case fun.() do
      {:error, :storage_busy} ->
        if System.monotonic_time(:millisecond) < until do
          Process.sleep(100)
          retry(fun, until)
        else
          {:error, :storage_busy}
        end

      result ->
        result
    end
  end

  defp await_ready(task, config, spec) do
    case Task.yield(task, 60_000) do
      {:ok, result} ->
        result

      nil ->
        for unit <-
              ~w(inception-identity inception-credentials inception-storage postgresql inception-migrate inception-enrollment inception-enable) do
          IO.puts(
            "bootstrap #{unit}: #{console(config, spec, "systemctl is-active --quiet #{unit}.service", 3000)}"
          )
        end

        diagnose_marshall(config, spec)
        await_ready(task, config, spec)
    end
  end

  defp diagnose_marshall(config, spec) do
    # Search a closed list of public error categories inside the guest. Only
    # category matches leave the console; never journal or exception contents.
    for category <- [
          "Invalid production deployment configuration",
          "Invalid production mail configuration",
          "MARSHALL_CLOAK_KEYS",
          "SECRET_KEY_BASE",
          "Failed at step",
          "Permission denied",
          "Failed to set up",
          "eacces",
          "enoent",
          "address already in use",
          "Invalid MARSHALL_DEFAULT_IMAGE_ID",
          "Could not start application",
          "Failed to create"
        ] do
      if console(
           config,
           spec,
           "journalctl -u marshall-inception.service --no-pager -o cat | grep -qiF '#{category}'",
           3000
         ) == :pass,
         do: IO.puts("Marshall failure category: #{category}")
    end

    for code <- [1, 2, 203, 217, 218, 226, 231, 245, 255] do
      if console(
           config,
           spec,
           "test $(systemctl show -p ExecMainStatus --value marshall-inception.service) = #{code}",
           3000
         ) == :pass,
         do: IO.puts("Marshall exit status: #{code}")
    end
  end

  # Only fixed predicates leave the guest; never print service logs or files.
  defp diagnose_ingress(config, spec) do
    # The gateways retry certificate publication while the inner Marshall
    # FleetEndpoint comes up.  Keep this diagnosis to fixed predicates so a
    # failed boot can distinguish a listener race from a crashed control plane
    # without exporting journals, credentials or terminal bytes.
    for port <- ~w(4443 5443) do
      if console(
           config,
           spec,
           "openssl s_client -brief -connect 127.0.0.1:#{port} -servername localhost -CAfile /run/inception-public/ca.crt -verify_return_error </dev/null >/dev/null 2>&1",
           3000
         ) == :pass,
        do: IO.puts("Inner TCP listener #{port}: listening")
    end

    for state <- ~w(active activating inactive failed) do
      if console(
           config,
           spec,
           "test $(systemctl show -p ActiveState --value marshall-inception.service) = #{state}",
           3000
         ) == :pass,
         do: IO.puts("Inner Marshall state: #{state}")
    end

    for substate <- ~w(running start failed dead exited) do
      if console(
           config,
           spec,
           "test $(systemctl show -p SubState --value marshall-inception.service) = #{substate}",
           3000
         ) == :pass,
         do: IO.puts("Inner Marshall substate: #{substate}")
    end

    for status <- ~w(0 1 2 9 137 143 203 217 226 231 245 255) do
      if console(
           config,
           spec,
           "test $(systemctl show -p ExecMainStatus --value marshall-inception.service) = #{status}",
           3000
         ) == :pass,
         do: IO.puts("Inner Marshall exit status: #{status}")
    end

    for {field, value} <- [
          {"Result", "exit-code"},
          {"Result", "signal"},
          {"Result", "timeout"},
          {"Result", "oom-kill"},
          {"ExecMainCode", "exited"},
          {"ExecMainCode", "killed"}
        ] do
      if console(
           config,
           spec,
           "test $(systemctl show -p #{field} --value marshall-inception.service) = #{value}",
           3000
         ) == :pass,
         do: IO.puts("Inner Marshall #{String.downcase(field)}: #{value}")
    end

    for category <- [
          "Invalid production deployment configuration",
          "Could not start application",
          "address already in use",
          "Failed at step",
          "Connection refused",
          "Permission denied"
        ] do
      if console(
           config,
           spec,
           "journalctl -u marshall-inception.service --no-pager -o cat | grep -qiF '#{category}'",
           3000
         ) == :pass,
         do: IO.puts("Inner Marshall failure category: #{category}")
    end

    for unit <-
          ~w(inception-ingress inception-namespace inception-enrollment marshall-inception inception-marshall-listener inception-porsche inception-audi
                   inception-dns-identity inception-dns porsche audi audi-dns inception-publication) do
      for state <- ~w(active failed activating inactive) do
        if console(
             config,
             spec,
             "test $(systemctl show -p ActiveState --value #{unit}.service) = #{state}",
             3000
           ) == :pass,
           do: IO.puts("Ingress #{unit}: #{state}")
      end

      for field <- ~w(MainPID NRestarts) do
        if console(
             config,
             spec,
             "test $(systemctl show -p #{field} --value #{unit}.service) != 0",
             3000
           ) == :pass,
           do: IO.puts("Ingress #{unit} #{field}: nonzero")
      end

      for category <- [
            "Permission denied",
            "Failed at step",
            "ModuleNotFoundError",
            "configuration unavailable",
            "identity unavailable",
            "Could not start application",
            "Connection refused",
            "certificate verify failed",
            "SSH host certificate unavailable",
            "gateway-url",
            "gateway-credential",
            "gateway-ca",
            "gateway-client",
            "gateway-connect",
            "gateway-tls",
            "gateway-tls-issuer",
            "gateway-tls-hostname",
            "gateway-tls-validity",
            "gateway-tls-protocol",
            "gateway-timeout",
            "gateway-dns",
            "gateway-http",
            "gateway-response",
            "gateway-token",
            "gateway-json",
            "gateway-version",
            "gateway-certificate",
            "key-generate",
            "key-read",
            "key-export",
            "key-format",
            "certificate-install",
            "invalid_request",
            "unauthorized",
            "host_key_conflict",
            "temporarily_unavailable",
            "unavailable",
            "Traceback",
            "KeyError"
          ] do
        if console(
             config,
             spec,
             "journalctl -u #{unit}.service --no-pager -o cat | grep -qiF '#{category}'",
             3000
           ) == :pass,
           do: IO.puts("Ingress #{unit} failure category: #{category}")
      end
    end

    for field <- ~w(porsche_host_key audi_host_key expires_at_ms) do
      if console(config, spec, "jq -e '.#{field} != null' /run/inception/publication.json", 3000) ==
           :pass,
         do: IO.puts("Ingress publication field present: #{field}")
    end
  end

  defp await(fun, until) do
    unless fun.() do
      if System.monotonic_time(:millisecond) >= until,
        do: raise("Inception fixture condition timed out")

      Process.sleep(100)
      await(fun, until)
    end
  end

  defp deadline(milliseconds), do: System.monotonic_time(:millisecond) + milliseconds
end

InceptionFixture.run()
