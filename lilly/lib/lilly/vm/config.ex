defmodule Lilly.VM.Config do
  @moduledoc "Trusted local driver configuration. It is never decoded from remote command fields."
  import Bitwise
  alias Lilly.Host.RootOwner
  alias Lilly.Network.Config, as: NetworkConfig
  alias Lilly.VM.Executable

  @enforce_keys [
    :state_dir,
    :network,
    :firecracker,
    :jailer,
    :unshare,
    :launch_guard,
    :boot_log_writer
  ]
  defstruct [
    :state_dir,
    :network,
    :firecracker,
    :jailer,
    :unshare,
    :launch_guard,
    :boot_log_writer,
    guest_trust_roots: [],
    checkpoint_image_ids: [],
    inception_smtp_file: nil,
    inception_image_id: nil,
    inception_proof_file: nil,
    inception_probe_id: nil,
    firecracker_logging: false
  ]

  @type t :: %__MODULE__{
          state_dir: Path.t(),
          network: NetworkConfig.t(),
          firecracker: Path.t(),
          jailer: Path.t(),
          unshare: Path.t(),
          launch_guard: Path.t(),
          boot_log_writer: Path.t(),
          guest_trust_roots: [binary()],
          checkpoint_image_ids: [String.t()],
          inception_smtp_file: Path.t() | nil,
          inception_image_id: String.t() | nil,
          inception_proof_file: Path.t() | nil,
          inception_probe_id: Path.t() | nil,
          firecracker_logging: boolean()
        }

  # @cc [owner:ghuntley,label:security] driver-executables-trusted-local
  # new/1 MUST reject untrusted executable ownership/ancestry and require static x86-64
  # Firecracker/jailer binaries from the same directory. Remote commands must not select these
  # executable paths.
  @spec new(map()) :: {:ok, t()} | {:error, :invalid_driver_configuration}
  def new(
        %{
          state_dir: state,
          network: %NetworkConfig{},
          firecracker: fc,
          jailer: jailer,
          unshare: unshare
        } = args
      )
      when map_size(args) in 5..12 do
    with true <-
           Map.keys(args) --
             [
               :state_dir,
               :network,
               :firecracker,
               :jailer,
               :unshare,
               :firecracker_logging,
               :inception_smtp_file,
               :inception_image_id,
               :inception_proof_file,
               :inception_probe_id,
               :guest_trust_roots,
               :checkpoint_image_ids
             ] == [],
         true <- valid_checkpoint_image_ids?(Map.get(args, :checkpoint_image_ids, [])),
         true <- valid_guest_trust_roots?(Map.get(args, :guest_trust_roots, [])),
         true <- is_boolean(Map.get(args, :firecracker_logging, false)),
         true <- inception_inputs?(args),
         true <- proof_inputs?(args),
         true <-
           is_binary(state) and Path.type(state) == :absolute and Path.expand(state) == state,
         true <- byte_size(state) <= 45 and not String.contains?(state, ["\0", "\n", "\r"]),
         true <- Enum.all?([fc, jailer, unshare], &is_binary/1),
         true <- Path.basename(fc) == "firecracker" and Path.basename(jailer) == "jailer",
         true <- Path.dirname(fc) == Path.dirname(jailer),
         true <- Enum.all?([fc, jailer, unshare], &trusted_executable?/1),
         true <- Executable.static_x86_64?(fc) and Executable.static_x86_64?(jailer),
         guard when is_binary(guard) <- System.find_executable("lilly-launch-guard"),
         {:ok, guard} <- resolve_executable(guard, 8),
         true <- trusted_executable?(guard),
         writer when is_binary(writer) <- System.find_executable("lilly-boot-log"),
         {:ok, writer} <- resolve_executable(writer, 8),
         true <- trusted_executable?(writer) do
      {:ok,
       struct!(
         __MODULE__,
         args
         |> Map.put(:launch_guard, guard)
         |> Map.put(:boot_log_writer, writer)
       )}
    else
      _ -> {:error, :invalid_driver_configuration}
    end
  end

  def new(_), do: {:error, :invalid_driver_configuration}

  # @cc [owner:ghuntley,label:security;recovery] checkpoint-qualification-local-only
  # Qualification MUST be a bounded unique list of exact content-addressed IDs
  # supplied by trusted operator configuration, never by execution commands.
  @spec valid_checkpoint_image_ids?(term()) :: boolean()
  defp valid_checkpoint_image_ids?(ids),
    do: OverallsProtocol.NativeAdmission.checkpoint_image_ids?(ids)

  defp valid_guest_trust_roots?(roots) when is_list(roots) and length(roots) <= 32 do
    Enum.all?(roots, fn pem ->
      is_binary(pem) and byte_size(pem) in 1..16_384 and
        length(:public_key.pem_decode(pem)) == 1 and
        match?([{:Certificate, _, :not_encrypted}], :public_key.pem_decode(pem))
    end)
  rescue
    _ -> false
  end

  defp valid_guest_trust_roots?(_), do: false

  # @cc [owner:ghuntley,label:security] inception-image-and-credential-pair
  # Inception delivery MUST require both an explicitly configured content-addressed
  # image and a valid private SMTP source. Either missing half MUST fail startup;
  # an ordinary deployment with neither configured remains valid.
  defp inception_inputs?(args) do
    case {args[:inception_image_id], args[:inception_smtp_file]} do
      {nil, nil} ->
        true

      {id, path} ->
        OverallsProtocol.ImageManifest.id?(id) and
          match?({:ok, _}, Lilly.VM.Credentials.load(path))
    end
  end

  defp proof_inputs?(args) do
    case {args[:inception_proof_file], args[:inception_probe_id]} do
      {nil, nil} ->
        true

      {file, probe} when is_binary(file) and is_binary(probe) ->
        OverallsProtocol.ImageManifest.id?(args[:inception_image_id]) and
          Path.type(file) == :absolute and Path.expand(file) == file and
          byte_size(file) in 1..4096 and not String.contains?(file, [<<0>>, "\n", "\r"]) and
          not String.starts_with?(file, "/nix/store/") and
          String.starts_with?(probe, "/nix/store/") and Path.expand(probe) == probe and
          byte_size(probe) in 1..4096 and not String.contains?(probe, [<<0>>, "\n", "\r"])

      _ ->
        false
    end
  end

  # @cc [owner:ghuntley,label:security] driver-helper-link-chain-trusted
  # A helper selected from PATH MUST resolve through no more than eight
  # root-owned executable links to a regular trusted executable. Ancestor
  # directory links MUST also be root-owned and resolve through at most eight
  # trusted directory links. Missing, cyclic or untrusted links fail closed.
  defp resolve_executable(path, remaining) when remaining >= 0 do
    with true <- Path.type(path) == :absolute and Path.expand(path) == path,
         true <- trusted_parent?(Path.dirname(path)),
         {:ok, stat} <- File.lstat(path) do
      case stat do
        %File.Stat{type: :regular} ->
          {:ok, path}

        %File.Stat{type: :symlink} when remaining > 0 ->
          with true <- RootOwner.root?(stat),
               {:ok, target} <- File.read_link(path) do
            resolve_executable(Path.expand(target, Path.dirname(path)), remaining - 1)
          else
            _ -> :error
          end

        _ ->
          :error
      end
    else
      _ -> :error
    end
  end

  defp resolve_executable(_, _), do: :error

  defp trusted_executable?(path) when is_binary(path) do
    with true <- Path.type(path) == :absolute and Path.expand(path) == path,
         {:ok, %File.Stat{type: :regular, mode: mode} = stat} <- File.lstat(path),
         true <- RootOwner.root?(stat),
         true <- band(mode, 0o111) != 0 and band(mode, 0o022) == 0,
         true <- trusted_parent?(Path.dirname(path)),
         do: true,
         else: (_ -> false)
  end

  defp trusted_executable?(_), do: false
  defp trusted_parent?(path), do: trusted_parent?(path, 8)
  defp trusted_parent?("/", _remaining), do: true

  defp trusted_parent?(path, remaining) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :directory, mode: mode} = stat} ->
        RootOwner.root?(stat) and (band(mode, 0o022) == 0 or band(mode, 0o1000) != 0) and
          trusted_parent?(Path.dirname(path), remaining)

      {:ok, %File.Stat{type: :symlink} = stat} when remaining > 0 ->
        with true <- RootOwner.root?(stat),
             {:ok, target} <- File.read_link(path) do
          trusted_parent?(Path.dirname(path), remaining - 1) and
            trusted_parent?(Path.expand(target, Path.dirname(path)), remaining - 1)
        else
          _ -> false
        end

      _ ->
        false
    end
  end
end
