defmodule Ziggy.Config do
  @moduledoc "Strict public configuration plus private systemd credential paths."
  # @cc [owner:ghuntley,label:security] ziggy-control-ipv4-origin
  # Control-plane origins MUST reject IPv6 literals, including scoped and
  # IPv4-mapped forms, before reading credentials or attempting a connection.
  @spec load(binary()) :: {:ok, map()} | {:error, :invalid_configuration}
  def load(path) do
    with {:ok, %File.Stat{type: :regular, size: size}} when size <= 16_384 <- File.lstat(path),
         {:ok, bytes} <- File.read(path),
         {:ok, value} when is_map(value) <- Jason.decode(bytes),
         true <-
           Enum.sort(
             Map.keys(
               Map.drop(value, [
                 "enabled_providers",
                 "openai_origin",
                 "agent_enabled",
                 "github_tools_release",
                 "executor_bootstrap_release",
                 "lyra_release"
               ])
             )
           ) ==
             Enum.sort(
               ~w(version host_id control_plane ca_file credential_file openai_key_file anthropic_key_file socket spool max_requests)
             ),
         1 <- value["version"],
         true <- OverallsProtocol.uuid?(value["host_id"]),
         %URI{
           scheme: "https",
           host: host,
           userinfo: nil,
           query: nil,
           fragment: nil,
           path: uri_path
         }
         when is_binary(host) and uri_path in [nil, ""] <- URI.parse(value["control_plane"]),
         false <- String.contains?(host, ":"),
         openai_origin when openai_origin in ["https://api.openai.com", "http://127.0.0.1:8080"] <-
           Map.get(value, "openai_origin", "https://api.openai.com"),
         agent_enabled when is_boolean(agent_enabled) <- Map.get(value, "agent_enabled", false),
         lyra_release when is_nil(lyra_release) or is_binary(lyra_release) <-
           Map.get(value, "lyra_release"),
         true <-
           is_nil(lyra_release) or
             (String.starts_with?(lyra_release, "/nix/store/") and
                Path.expand(lyra_release) == lyra_release),
         {:ok, update_artifact} <- load_update_artifact(lyra_release),
         github_release <- Map.get(value, "github_tools_release"),
         true <-
           is_nil(github_release) or
             (is_binary(github_release) and String.starts_with?(github_release, "/nix/store/") and
                Path.expand(github_release) == github_release),
         {:ok, github_tools} <- Ziggy.ToolRelease.load(github_release),
         bootstrap_root <- Map.get(value, "executor_bootstrap_release"),
         true <-
           is_nil(bootstrap_root) or
             (is_binary(bootstrap_root) and String.starts_with?(bootstrap_root, "/nix/store/") and
                Path.expand(bootstrap_root) == bootstrap_root),
         {:ok, bootstrap_release} <- Ziggy.BootstrapRelease.load(bootstrap_root),
         true <- Enum.all?(~w(socket spool), &private_path?(value[&1])),
         true <- byte_size(value["socket"]) <= 107,
         maximum when is_integer(maximum) and maximum in 1..100_000 <- value["max_requests"],
         {:ok, token} <- Ziggy.Credential.read(value["credential_file"]),
         true <- byte_size(token) == 80,
         {:ok, credentials} <- provider_credentials(value),
         true <- is_binary(value["ca_file"]) and File.regular?(value["ca_file"]) do
      {:ok,
       %{
         host_id: value["host_id"],
         socket: value["socket"],
         spool: value["spool"],
         max_requests: maximum,
         openai_origin: openai_origin,
         agent_enabled: agent_enabled,
         lyra_release: lyra_release,
         update_artifact: update_artifact,
         github_tools: github_tools,
         bootstrap_release: bootstrap_release,
         credentials: credentials,
         control: %{
           origin: value["control_plane"],
           token: token,
           ca_file: value["ca_file"],
           host_id: value["host_id"],
           client: Ziggy.ControlClient
         }
       }}
    else
      _ -> {:error, :invalid_configuration}
    end
  rescue
    _ -> {:error, :invalid_configuration}
  end

  # @cc [owner:ghuntley,label:deployment] explicit-provider-selection
  # An explicit provider selection MUST be nonempty, unique and known. Only
  # selected providers' keys may enter the runtime catalog or inference client.
  # Omitted selection MUST retain both providers for existing configurations.
  defp provider_credentials(value) do
    providers = Map.get(value, "enabled_providers", ["openai", "anthropic"])

    if is_list(providers) and providers != [] and Enum.uniq(providers) == providers and
         Enum.all?(providers, &(&1 in ["openai", "anthropic"])) do
      Enum.reduce_while(providers, {:ok, %{}}, fn provider, {:ok, acc} ->
        case Ziggy.Credential.read(value[provider <> "_key_file"]) do
          {:ok, key} ->
            name = if provider == "openai", do: :openai, else: :anthropic
            {:cont, {:ok, Map.put(acc, name, key)}}

          _ ->
            {:halt, {:error, :invalid_configuration}}
        end
      end)
    else
      {:error, :invalid_configuration}
    end
  end

  defp private_path?(value) when is_binary(value),
    do:
      Path.type(value) == :absolute and Path.expand(value) == value and
        not String.starts_with?(value, "/nix/store/")

  defp private_path?(_), do: false

  defp load_update_artifact(nil), do: {:ok, nil}

  # The Nix store release is immutable for this Ziggy process. Hash once at
  # startup so frequent guest manifest polls do not rehash 100 MiB per VM.
  defp load_update_artifact(root) do
    path = Path.join([root, "bin", "linux-amd64"])

    with {:ok, %File.Stat{type: :regular, size: size}} <- File.stat(path),
         true <- size > 0 and size <= 104_857_600 do
      digest =
        path
        |> File.stream!(65_536, [])
        |> Enum.reduce(:crypto.hash_init(:sha256), &:crypto.hash_update(&2, &1))
        |> :crypto.hash_final()
        |> Base.encode16(case: :lower)

      {:ok, %{path: path, digest: digest, size: size}}
    else
      _ -> {:error, :invalid_configuration}
    end
  end
end
