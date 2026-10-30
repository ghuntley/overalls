defmodule Lilly.Network.Guest do
  @moduledoc "Validated per-VM TAP and anti-spoofing identity."
  @enforce_keys [
    :vm_id,
    :profile,
    :slot,
    :address,
    :addresses,
    :gateway,
    :mac,
    :gateway_mac,
    :tap,
    :guard,
    :uid
  ]
  defstruct [
    :vm_id,
    :profile,
    :slot,
    :address,
    :addresses,
    :gateway,
    :mac,
    :gateway_mac,
    :tap,
    :guard,
    :uid
  ]

  @type t :: %__MODULE__{
          vm_id: String.t(),
          profile: OverallsProtocol.AddressPool.profile(),
          slot: pos_integer(),
          address: String.t(),
          addresses: [String.t()],
          gateway: String.t(),
          mac: String.t(),
          gateway_mac: String.t(),
          tap: String.t(),
          guard: String.t(),
          uid: pos_integer()
        }

  # @cc [owner:ghuntley,label:security] guest-address-mac-uid-consistency
  # new/3 MUST derive address, MAC and reserved UID from the same validated profile/slot pair,
  # with distinct identities across profiles. An invalid VM UUID or reserved address slot must
  # fail before any host effect.
  @spec new(String.t(), OverallsProtocol.AddressPool.profile(), integer()) ::
          {:ok, t()} | {:error, :invalid_guest_network}
  def new(vm, profile, slot) do
    with true <- OverallsProtocol.uuid?(vm),
         {:ok, [address | _] = addresses} <- OverallsProtocol.AddressPool.addresses(profile, slot) do
      octet = %{customer: 10, standard: 20, oss: 30, inception: 40}[profile]

      mac = format_mac([2, 252, 10, octet, div(slot, 256), rem(slot, 256)])

      # @cc [owner:ghuntley,label:recovery;isolation] guest-gateway-mac-host-independent
      # The host-side TAP MAC MUST depend only on the profile, never on host, slot or TAP
      # creation, so a memory-restored guest's cached gateway neighbour stays valid on
      # any destination (ADR-0199). It MUST stay locally administered unicast and
      # outside the guest MAC space (third octet 0 versus 10).
      gateway_mac = format_mac([2, 252, 0, octet, 0, 1])

      tag = :crypto.hash(:sha256, vm) |> Base.encode16(case: :lower) |> binary_part(0, 12)

      {:ok,
       %__MODULE__{
         vm_id: vm,
         profile: profile,
         slot: slot,
         address: address,
         addresses: addresses,
         gateway: "10.#{octet}.0.1",
         mac: mac,
         gateway_mac: gateway_mac,
         tap: "lv" <> tag,
         guard: "guard_" <> String.replace(vm, "-", ""),
         uid: 1_000_000 + (div(octet, 10) - 1) * 65_536 + slot
       }}
    else
      _ -> {:error, :invalid_guest_network}
    end
  end

  @spec format_mac([0..255]) :: String.t()
  defp format_mac(octets) do
    Enum.map_join(octets, ":", fn n ->
      n |> Integer.to_string(16) |> String.downcase() |> String.pad_leading(2, "0")
    end)
  end
end
