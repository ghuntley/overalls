defmodule Marshall.CloneReportRejectionFixture do
  @moduledoc false
  import Bitwise

  @stages ~w(report_shape sample_future sample_expired pool_schema pool_observed_at pool_set storage_identity capacity_schema capacity_bounds image_ids architecture)a
  @type stage ::
          :report_shape
          | :sample_future
          | :sample_expired
          | :pool_schema
          | :pool_observed_at
          | :pool_set
          | :storage_identity
          | :capacity_schema
          | :capacity_bounds
          | :image_ids
          | :architecture

  # @cc [owner:ghuntley,label:verification] report-guard-result-preservation
  # A wrapped predicate MUST be evaluated once by its caller and returned unchanged.
  # Only false may publish a rejection; this is guard evidence, never a committed
  # report or outcome. Shape rejection MUST NOT inspect malformed report fields.
  @spec check(stage(), boolean(), integer() | nil) :: boolean()
  def check(stage, result, age) do
    if result == false, do: reject(stage, age)
    result
  end

  # @cc [owner:ghuntley,label:verification;security] report-rejection-private-finite-evidence
  # Only the disposable fixture may install this module. Rejection evidence MUST
  # contain just a finite stage and signed age from the exact guarded sample and
  # database time (nil only for shape rejection). Preserve the first rejection per
  # stage per replica while armed, outside transaction rollback, in at most eleven
  # private 160-byte files plus eleven bounded staging files. No report, host ID,
  # credential, timestamp, arbitrary state or application event may be exported.
  # A missing/unwritable/disarmed sink MUST NOT alter the original guard result.
  @spec reject(stage(), integer() | nil) :: :ok
  def reject(stage, age) when stage in @stages do
    valid_age = (stage == :report_shape and age == nil) or is_integer(age)

    try do
      with true <- valid_age,
           runtime when is_binary(runtime) <- System.get_env("RELEASE_TMP"),
           root = Path.join(runtime, "clone-report-rejections"),
           true <- private_directory?(root),
           true <- armed?(root) do
        publish(root, stage, age)
      end
    rescue
      _ -> :ok
    catch
      _, _ -> :ok
    end

    :ok
  end

  @spec private_directory?(Path.t()) :: boolean()
  defp private_directory?(root) do
    case File.lstat(root) do
      {:ok, %File.Stat{type: :directory, mode: mode}} -> band(mode, 0o777) == 0o700
      _ -> false
    end
  end

  @spec armed?(Path.t()) :: boolean()
  defp armed?(root) do
    case File.lstat(Path.join(root, "armed")) do
      {:ok, %File.Stat{type: :regular, mode: mode}} -> band(mode, 0o777) == 0o600
      _ -> false
    end
  end

  @spec publish(Path.t(), stage(), integer() | nil) :: :ok
  defp publish(root, stage, age) do
    path = Path.join(root, Atom.to_string(stage) <> ".json")
    temporary = path <> ".tmp"
    bytes = JSON.encode!(%{stage: stage, sample_age_ms: age})

    with true <- byte_size(bytes) <= 160,
         {:error, :enoent} <- File.lstat(path),
         {:ok, file} <- File.open(temporary, [:write, :exclusive, :binary]) do
      result =
        try do
          # Publication and collection synchronize through this existing staging
          # file. A writer arriving after disarm cannot publish a late sample.
          with :ok <- File.chmod(temporary, 0o600),
               {:error, :enoent} <- File.lstat(path),
               true <- armed?(root),
               :ok <- IO.binwrite(file, bytes),
               :ok <- File.rename(temporary, path),
               do: :ok
        after
          File.close(file)
        end

      if result != :ok, do: File.rm(temporary)
    end

    :ok
  end
end
