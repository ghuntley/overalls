defmodule Lilly.Network.IdentityTest do
  use ExUnit.Case, async: true
  import Hegel
  import Hegel.Gen
  alias Lilly.Network.{Config, Guest, Ingress, Policy}
  @host "af4bdc65-e17f-49ae-9bfb-cbe4cf0a4071"
  @vm "fb8f7045-82cb-4a05-afdf-e10eb405dc6f"

  property "nested service targets stay on the same paired Inception slot" do
    slot = draw("slot", integer(2..65534))
    {:ok, guest} = Guest.new(@vm, :inception, slot)

    for {service, octet, port, kind} <- [
          {:control_https, 40, 443, :web},
          {:porsche_ssh, 40, 22, :ssh},
          {:audi_https, 41, 443, :web},
          {:audi_ssh, 41, 22, :ssh}
        ] do
      binding = %{service: service, port: port}
      assert {:ok, {address, ^port, mark}} = Ingress.target(guest, binding)
      assert address == "10.#{octet}.#{div(slot, 256)}.#{rem(slot, 256)}"
      assert mark == Policy.ingress_mark(kind)
      assert {:error, :ingress_unavailable} = Ingress.target(guest, %{binding | port: port + 1})

      assert {:error, :ingress_unavailable} =
               Ingress.target(%{guest | addresses: ["127.0.0.1", "127.0.0.2"]}, binding)

      for profile <- [:customer, :standard, :oss] do
        {:ok, ordinary} = Guest.new(@vm, profile, slot)
        assert {:error, :ingress_unavailable} = Ingress.target(ordinary, binding)
      end
    end
  end

  property "profile identity keeps addresses, MACs and reserved UIDs distinct" do
    slot = draw("slot", integer(2..65534))

    guests =
      for profile <- [:customer, :standard, :oss, :inception] do
        {:ok, guest} = Guest.new(@vm, profile, slot)
        assert guest.uid in 1_000_002..1_262_142
        assert byte_size(guest.tap) <= 15
        guest
      end

    for key <- [:address, :mac, :uid] do
      assert guests |> Enum.map(&Map.fetch!(&1, key)) |> Enum.uniq() |> length() == 4
    end
  end

  property "gateway MAC is host- and slot-independent and outside the guest MAC space" do
    slot = draw("slot", integer(2..65534))
    other_slot = draw("other_slot", integer(2..65534))
    other_vm = Lilly.UUID.generate()

    for profile <- [:customer, :standard, :oss, :inception] do
      {:ok, guest} = Guest.new(@vm, profile, slot)
      {:ok, moved} = Guest.new(other_vm, profile, other_slot)
      octet = %{customer: 10, standard: 20, oss: 30, inception: 40}[profile]
      hex = octet |> Integer.to_string(16) |> String.downcase() |> String.pad_leading(2, "0")

      assert guest.gateway_mac == "02:fc:00:#{hex}:00:01"
      assert moved.gateway_mac == guest.gateway_mac
      refute guest.gateway_mac == guest.mac
      assert [first | _] = String.split(guest.gateway_mac, ":")
      assert Bitwise.band(String.to_integer(first, 16), 0b11) == 0b10
    end
  end

  property "guest address, gateway, MAC and reserved UID use the same profile octet" do
    slot = draw("slot", integer(2..65534))

    for profile <- [:customer, :standard, :oss, :inception] do
      {:ok, guest} = Guest.new(@vm, profile, slot)
      {:ok, canonical_address} = OverallsProtocol.AddressPool.address(profile, slot)
      ["10", octet_text, third, fourth] = String.split(canonical_address, ".")
      octet = String.to_integer(octet_text)

      assert guest.address == canonical_address
      assert guest.gateway == "10.#{octet}.0.1"

      assert guest.mac ==
               Enum.map_join(
                 [2, 252, 10, octet, div(slot, 256), rem(slot, 256)],
                 ":",
                 fn byte ->
                   byte
                   |> Integer.to_string(16)
                   |> String.downcase()
                   |> String.pad_leading(2, "0")
                 end
               )

      assert guest.uid == 1_000_000 + (div(octet, 10) - 1) * 65_536 + slot
      assert third == Integer.to_string(div(slot, 256))
      assert fourth == Integer.to_string(rem(slot, 256))
      assert Policy.guard(guest) =~ "ether saddr != #{guest.mac} counter drop"
    end
  end

  property "editor targets retain profile-derived addresses and one dedicated port" do
    slot = draw("slot", integer(2..65534))
    other_port = draw("other_port", integer(1..65535) |> filter(&(&1 != 4444)))

    for profile <- [:customer, :standard, :oss, :inception] do
      {:ok, guest} = Guest.new(@vm, profile, slot)

      assert {:ok, {address, 4444, mark}} =
               Ingress.target(guest, %{service: :editor, port: 4444})

      assert address == guest.address
      assert mark == Policy.ingress_mark(:editor)

      assert {:error, :ingress_unavailable} =
               Ingress.target(guest, %{service: :web, port: 4444})

      assert {:error, :ingress_unavailable} =
               Ingress.target(guest, %{service: :editor, port: other_port})

      assert {:error, :ingress_unavailable} =
               Ingress.target(%{guest | address: "127.0.0.1"}, %{service: :editor, port: 4444})
    end

    assert length(Enum.uniq(Enum.map([:ssh, :web, :editor], &Policy.ingress_mark/1))) == 3
  end

  property "customer web sockets fail for every admitted port and slot" do
    port = draw("port", integer(1..65535))
    slot = draw("slot", integer(2..65534))
    {:ok, network} = Config.new(@host, "eth0", [], "/var/lib/lilly", true)
    {:ok, guest} = Guest.new(@vm, :customer, slot)

    assert {:error, :ingress_unavailable} =
             Ingress.connect(network, guest, %{service: :web, port: port})
  end

  property "Inception guard admits only its paired slot, with the same MAC and gateway" do
    slot = draw("slot", integer(2..65534))
    assert {:ok, guest} = Guest.new(@vm, :inception, slot)
    assert [guest.address, "10.41.#{div(slot, 256)}.#{rem(slot, 256)}"] == guest.addresses
    policy = Policy.guard(guest)
    sources = "{ " <> Enum.join(guest.addresses, ", ") <> " }"
    assert policy =~ "arp saddr ip != #{sources} counter drop"
    assert policy =~ "ip saddr #{sources} counter accept"
    assert policy =~ "ether saddr != #{guest.mac} counter drop"
    assert policy =~ "arp daddr ip != #{guest.gateway} counter drop"
  end

  test "operator interface/CIDR validation rejects text that can alter nft programs" do
    assert {:ok, _} =
             Config.new(@host, "eth0", ["203.0.113.0/24", "1.1.1.1/32"], "/var/lib/lilly")

    for interface <- ["eth0\nflush ruleset", "x\"", "--help", String.duplicate("a", 16)] do
      assert {:error, _} = Config.new(@host, interface, [], "/var/lib/lilly")
    end

    for cidr <- ["1.2.3.4/24", "256.0.0.0/8", "1.1.1.1", "::/0", "1.1.1.1/32; flush ruleset"] do
      refute Config.cidr?(cidr)
    end
  end

  test "local SSH exceptions are explicit and cannot alter the forwarding policy" do
    {:ok, disabled} = Config.new(@host, "eth0", [], "/var/lib/lilly")
    {:ok, enabled} = Config.new(@host, "eth0", [], "/var/lib/lilly", true)
    {:ok, guest} = Guest.new(@vm, :customer, 2)
    assert {:error, :ingress_unavailable} = Ingress.connect(disabled, guest)

    assert {:error, :invalid_network_configuration} =
             Config.new(@host, "eth0", [], "/var/lib/lilly", "true")

    refute Policy.router(disabled) =~ "meta mark"
    assert Policy.router(enabled) =~ "tcp dport 22"
    assert Policy.router(enabled) =~ "ct direction reply"
    assert Policy.root(enabled) == Policy.root(disabled)
    [_, old_forward] = String.split(Policy.router(disabled), "chain forward", parts: 2)
    [_, new_forward] = String.split(Policy.router(enabled), "chain forward", parts: 2)
    assert new_forward == old_forward

    assert {:error, :ingress_unavailable} =
             Ingress.connect(%{enabled | namespace: "other"}, guest)

    assert {:error, :ingress_unavailable} =
             Ingress.connect(enabled, %{guest | address: "127.0.0.1"})

    assert {:error, :ingress_unavailable} = Ingress.connect(enabled, %{guest | tap: "lo"})
  end
end
