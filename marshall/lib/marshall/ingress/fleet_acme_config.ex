defmodule Marshall.Ingress.FleetACMEConfig do
  @moduledoc "Validated operator configuration for one PostgreSQL-backed wildcard issuer."

  alias Marshall.Ingress.ACME.Transport

  @type t :: %{
          zone: binary(),
          directory: binary(),
          issuer_ca_file: binary(),
          roots_file: binary(),
          nameservers: [{:inet.ip4_address(), :inet.port_number()}],
          accept_terms: boolean()
        }

  # @cc [owner:ghuntley,label:security;deployment] fleet-acme-issuer-selection
  # Only an explicitly selected serving replica may configure the issuer queue.
  # Its directory, CA roots and one to eight distinct authoritative DNS peers
  # (ADR-0285) MUST validate before any ACME operation. Missing configuration
  # MUST disable issuance.
  @spec from_env(map()) :: {:ok, t() | nil} | {:error, :invalid_configuration}
  def from_env(env) when is_map(env) do
    case Map.get(env, "MARSHALL_FLEET_ACME_DIRECTORY") do
      nil -> {:ok, nil}
      directory -> decode(env, directory)
    end
  end

  defp decode(env, directory) do
    with zone when is_binary(zone) <- Map.get(env, "MARSHALL_INGRESS_ZONE"),
         ca when is_binary(ca) <- Map.get(env, "MARSHALL_FLEET_ACME_ISSUER_CA_FILE"),
         roots when is_binary(roots) <- Map.get(env, "MARSHALL_FLEET_ACME_ROOTS_FILE"),
         {:ok, _} <- Transport.new(directory, cacertfile: ca),
         true <- regular_file?(ca) and regular_file?(roots),
         {:ok, peers} <- JSON.decode(Map.get(env, "MARSHALL_FLEET_ACME_NAMESERVERS", "")),
         true <- is_list(peers) and length(peers) in 1..8,
         {:ok, peers} <- parse_peers(peers),
         terms when terms in ["true", "false"] <-
           Map.get(env, "MARSHALL_FLEET_ACME_ACCEPT_TERMS") do
      {:ok,
       %{
         zone: zone,
         directory: directory,
         issuer_ca_file: ca,
         roots_file: roots,
         nameservers: peers,
         accept_terms: terms == "true"
       }}
    else
      _ -> {:error, :invalid_configuration}
    end
  end

  defp parse_peers(peers) do
    decoded = Enum.map(peers, &parse_peer/1)

    if Enum.all?(decoded, &match?({:ok, _}, &1)) do
      values = Enum.map(decoded, &elem(&1, 1))
      if Enum.uniq(values) == values, do: {:ok, values}, else: :error
    else
      :error
    end
  end

  defp parse_peer(%{"address" => address, "port" => port} = value)
       when map_size(value) == 2 and is_binary(address) and byte_size(address) <= 15 and
              is_integer(port) and port in 1..65_535 do
    case :inet.parse_ipv4strict_address(String.to_charlist(address)) do
      {:ok, {a, _, _, _} = ip} when a in 1..223 -> {:ok, {ip, port}}
      _ -> :error
    end
  end

  defp parse_peer(_), do: :error

  defp regular_file?(path) when is_binary(path) and byte_size(path) in 1..4096 do
    Path.type(path) == :absolute and Path.expand(path) == path and
      match?(
        {:ok, %File.Stat{type: :regular, size: size}} when size in 1..1_048_576,
        File.stat(path)
      )
  end

  defp regular_file?(_), do: false
end
