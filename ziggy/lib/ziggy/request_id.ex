defmodule Ziggy.RequestId do
  @moduledoc "Canonical UUIDv7 identities for individual inference attempts."

  # @cc [owner:ghuntley,label:protocol] inference-request-uuid-v7
  # New inference identities MUST encode the Unix millisecond timestamp, version
  # 7 and RFC variant bits with cryptographic randomness in the remaining bits.
  # Only canonical lowercase UUIDv7 identities may be forwarded as request IDs.
  @spec generate() :: OverallsProtocol.uuid()
  def generate do
    <<random_a::12, random_b::62, _::6>> = :crypto.strong_rand_bytes(10)

    <<System.system_time(:millisecond)::48, 7::4, random_a::12, 2::2, random_b::62>>
    |> Base.encode16(case: :lower)
    |> then(fn <<a::binary-8, b::binary-4, c::binary-4, d::binary-4, e::binary-12>> ->
      "#{a}-#{b}-#{c}-#{d}-#{e}"
    end)
  end

  @spec valid?(term()) :: boolean()
  def valid?(id) when is_binary(id) and byte_size(id) == 36,
    do:
      Regex.match?(
        ~r/\A[0-9a-f]{8}-[0-9a-f]{4}-7[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\z/,
        id
      )

  def valid?(_), do: false
end
