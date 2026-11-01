defmodule Lilly.Host.Identity do
  @moduledoc "Application-specific host identity; raw systemd machine IDs never leave this boundary."
  @spec read() :: {:ok, String.t()} | {:error, :machine_identity_unavailable}
  def read do
    with {:ok, %File.Stat{type: :regular, size: size} = stat} <- File.lstat("/etc/machine-id"),
         true <- Lilly.Host.RootOwner.root?(stat),
         true <- size in [32, 33],
         {:ok, bytes} <- File.read("/etc/machine-id"),
         {:ok, id} <- derive(bytes),
         do: {:ok, id},
         else: (_ -> {:error, :machine_identity_unavailable})
  end

  # @cc [owner:ghuntley,label:security] machine-id-application-binding
  # derive/1 MUST reject uninitialized, malformed or all-zero machine IDs and return only the
  # application-specific HMAC-SHA256 identity, never the raw machine ID; the optional trailing
  # newline must not change identity.
  @spec derive(term()) :: {:ok, String.t()} | {:error, :invalid_machine_identity}
  def derive(bytes) when is_binary(bytes) do
    with true <- Regex.match?(~r/\A[0-9a-f]{32}\n?\z/, bytes),
         {:ok, raw} <- Base.decode16(String.trim_trailing(bytes, "\n"), case: :lower),
         true <- raw != <<0::128>> do
      # Frozen derivation label: enrolled host identities were derived with it
      # before the product rename and every stored copy must keep matching.
      digest = :crypto.mac(:hmac, :sha256, "kittens.lilly.host.v1", raw)
      {:ok, "sha256:" <> Base.encode16(digest, case: :lower)}
    else
      _ -> {:error, :invalid_machine_identity}
    end
  end

  def derive(_), do: {:error, :invalid_machine_identity}
end
