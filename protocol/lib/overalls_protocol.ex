defmodule OverallsProtocol do
  @moduledoc "Shared ZFS capacity reports and bounded wire primitives. Pure, bounded validation."
  @max_integer 9_223_372_036_854_775_807
  @max_body 1_048_576
  @max_commands 16
  @type uuid :: String.t()
  @type observed_pool :: %{
          optional(:observed_at) => DateTime.t(),
          storage: OverallsProtocol.Storage.wire_observation(),
          id: uuid(),
          total_bytes: non_neg_integer(),
          free_bytes: non_neg_integer(),
          allocations: %{uuid() => non_neg_integer()},
          checkpoint_allocations: %{uuid() => non_neg_integer()}
        }
  @type unavailable_pool :: %{
          id: uuid(),
          unavailable: true,
          storage: OverallsProtocol.Storage.identity()
        }
  @type busy_pool :: %{
          id: uuid(),
          busy: true,
          storage: OverallsProtocol.Storage.identity()
        }
  @type pool :: observed_pool() | unavailable_pool() | busy_pool()
  @type report :: %{
          optional(:capacity) => map() | nil,
          sequence: pos_integer(),
          sampled_at: DateTime.t(),
          effective_cores: non_neg_integer(),
          effective_memory_bytes: non_neg_integer(),
          inventory: map(),
          pools: [pool()]
        }
  @type failure :: {:error, :invalid_message | :unsupported_version | :message_too_large}

  @spec max_body() :: pos_integer()
  def max_body, do: @max_body
  @spec max_commands() :: pos_integer()
  def max_commands, do: @max_commands

  # @cc [owner:ghuntley,label:protocol;security] wire-body-bound
  # decode/1 MUST reject bodies larger than 1 MiB before JSON decoding and accept only a JSON
  # object; malformed or non-object JSON returns invalid_message.
  @spec decode(binary()) :: {:ok, map()} | failure()
  def decode(body) when is_binary(body) and byte_size(body) <= @max_body do
    case JSON.decode(body) do
      {:ok, value} when is_map(value) -> {:ok, value}
      _ -> {:error, :invalid_message}
    end
  end

  def decode(_), do: {:error, :message_too_large}

  # @cc [owner:ghuntley,label:capacity] report-unknown-is-not-zero
  # report/1 MUST preserve nil as an absent observation. A present report must carry a positive
  # sequence, UTC timestamp, nonnegative signed-64-bit capacities and at most 64 uniquely
  # identified pools; invalid data must not become zero capacity.
  @spec report(term()) :: {:ok, report() | nil} | failure()
  def report(nil), do: {:ok, nil}

  def report(
        %{
          "sequence" => seq,
          "sampled_at" => sampled,
          "effective_cores" => cores,
          "effective_memory_bytes" => memory,
          "inventory" => inventory,
          "pools" => pools
        } = value
      )
      when map_size(value) in [6, 7] do
    with true <- positive?(seq) and non_negative?(cores) and non_negative?(memory),
         true <- is_binary(sampled),
         {:ok, time, 0} <- DateTime.from_iso8601(sampled),
         true <- inventory?(inventory),
         true <-
           Map.keys(value) --
             ~w(sequence sampled_at effective_cores effective_memory_bytes inventory pools capacity) ==
             [],
         true <- OverallsProtocol.Capacity.valid?(Map.get(value, "capacity")),
         true <- is_list(pools) and length(pools) <= 64,
         {:ok, decoded} <- traverse(pools, &pool/1),
         ids = Enum.map(decoded, & &1.id),
         true <- length(Enum.uniq(ids)) == length(ids) do
      {:ok,
       %{
         sequence: seq,
         sampled_at: time,
         effective_cores: cores,
         effective_memory_bytes: memory,
         inventory: inventory,
         pools: decoded
       }
       |> maybe_capacity(value)}
    else
      _ -> {:error, :invalid_message}
    end
  end

  def report(_), do: {:error, :invalid_message}

  @spec encode_report(report() | nil) :: map() | nil
  def encode_report(nil), do: nil

  def encode_report(report) do
    encoded = %{
      "sequence" => report.sequence,
      "sampled_at" => DateTime.to_iso8601(report.sampled_at),
      "effective_cores" => report.effective_cores,
      "effective_memory_bytes" => report.effective_memory_bytes,
      "inventory" => report.inventory,
      "pools" => Enum.map(report.pools, &encode_pool/1)
    }

    if Map.has_key?(report, :capacity),
      do: Map.put(encoded, "capacity", report.capacity),
      else: encoded
  end

  defp maybe_capacity(report, value) do
    if Map.has_key?(value, "capacity"),
      do: Map.put(report, :capacity, value["capacity"]),
      else: report
  end

  defp encode_pool(%{busy: true} = pool) do
    %{
      "id" => pool.id,
      "busy" => true,
      "storage" => OverallsProtocol.Storage.encode(pool.storage)
    }
  end

  defp encode_pool(%{unavailable: true} = pool) do
    %{
      "id" => pool.id,
      "unavailable" => true,
      "storage" => OverallsProtocol.Storage.encode(pool.storage)
    }
  end

  defp encode_pool(pool) do
    encoded = %{
      "id" => pool.id,
      "total_bytes" => pool.total_bytes,
      "free_bytes" => pool.free_bytes,
      "allocations" => pool.allocations,
      "checkpoint_allocations" => Map.get(pool, :checkpoint_allocations, %{}),
      "storage" => OverallsProtocol.Storage.encode(pool.storage)
    }

    case Map.fetch(pool, :observed_at) do
      {:ok, %DateTime{} = observed} ->
        Map.put(encoded, "observed_at", DateTime.to_iso8601(observed))

      :error ->
        encoded
    end
  end

  @spec uuid?(term()) :: boolean()
  def uuid?(id) when is_binary(id) and byte_size(id) == 36,
    do: Regex.match?(~r/\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/, id)

  def uuid?(_), do: false

  # @cc [owner:ghuntley,label:capacity] busy-pool-has-no-capacity
  # A busy pool (transient contention: the pool lock or moving usage counters)
  # MUST carry exactly its ID, configured storage identity and busy=true,
  # with no diagnostic fields, counters or credit. It is not an observation.
  defp pool(%{"id" => id, "busy" => true, "storage" => storage} = value)
       when map_size(value) == 3 do
    with true <- uuid?(id),
         {:ok, identity} <- OverallsProtocol.Storage.identity(storage) do
      {:ok, %{id: id, busy: true, storage: identity}}
    else
      _ -> {:error, :invalid_message}
    end
  end

  # @cc [owner:ghuntley,label:capacity] unavailable-pool-has-no-capacity
  # An unavailable pool MUST carry exactly its ID, configured storage identity,
  # unavailable=true. It MUST NOT carry
  # capacity counters or allocation credit. Identity is not a native observation.
  defp pool(%{"id" => id, "unavailable" => true, "storage" => storage} = value)
       when map_size(value) == 3 do
    with true <- uuid?(id),
         {:ok, identity} <- OverallsProtocol.Storage.identity(storage) do
      {:ok, %{id: id, unavailable: true, storage: identity}}
    else
      _ -> {:error, :invalid_message}
    end
  end

  # @cc [owner:ghuntley,label:capacity] pool-credit-cannot-exceed-used
  # pool/1 MUST reject allocation credit exceeding total_bytes minus free_bytes, free bytes
  # exceeding total, or more than 4096 VM allocations. Required ZFS observations
  # MUST bind explicit identity and agree with physical totals and quota.

  # @cc [owner:ghuntley,label:capacity;protocol] pool-observed-at-optional
  # An observed pool MAY carry observed_at, the UTC time its native read began
  # (ADR-0140, pool observer). It MUST be an ISO 8601 UTC timestamp; any other
  # value rejects the report. An absent observed_at means the report's
  # sampled_at, so reports from hosts without a pool observer keep their meaning.
  defp pool(%{"observed_at" => observed} = value) when map_size(value) == 7 do
    with true <- is_binary(observed),
         {:ok, %DateTime{} = time, 0} <- DateTime.from_iso8601(observed),
         {:ok, decoded} <- pool(Map.delete(value, "observed_at")),
         false <- Map.has_key?(decoded, :busy) or Map.has_key?(decoded, :unavailable) do
      {:ok, Map.put(decoded, :observed_at, time)}
    else
      _ -> {:error, :invalid_message}
    end
  end

  defp pool(
         %{
           "id" => id,
           "total_bytes" => total,
           "free_bytes" => free,
           "allocations" => allocations,
           "checkpoint_allocations" => checkpoint_allocations
         } = pool
       )
       when map_size(pool) == 6 do
    if uuid?(id) and non_negative?(total) and non_negative?(free) and free <= total and
         is_map(allocations) and map_size(allocations) <= 4096 and
         Enum.all?(allocations, fn {vm, bytes} -> uuid?(vm) and non_negative?(bytes) end) and
         is_map(checkpoint_allocations) and map_size(checkpoint_allocations) <= 4096 and
         Enum.all?(checkpoint_allocations, fn {vm, bytes} ->
           uuid?(vm) and non_negative?(bytes)
         end) and
         Enum.sum(Map.values(allocations)) + Enum.sum(Map.values(checkpoint_allocations)) <=
           total - free do
      decoded = %{
        id: id,
        total_bytes: total,
        free_bytes: free,
        allocations: allocations,
        checkpoint_allocations: checkpoint_allocations
      }

      case {map_size(pool), Map.fetch(pool, "storage")} do
        {6, {:ok, storage}} ->
          with {:ok, storage} <- OverallsProtocol.Storage.observation(storage),
               true <- OverallsProtocol.Storage.coherent?(storage, total, free) do
            {:ok, Map.put(decoded, :storage, storage)}
          else
            _ -> {:error, :invalid_message}
          end

        _ ->
          {:error, :invalid_message}
      end
    else
      {:error, :invalid_message}
    end
  end

  defp pool(_), do: {:error, :invalid_message}

  defp traverse(values, fun) do
    Enum.reduce_while(values, {:ok, []}, fn value, {:ok, acc} ->
      case fun.(value) do
        {:ok, decoded} -> {:cont, {:ok, [decoded | acc]}}
        _ -> {:halt, {:error, :invalid_message}}
      end
    end)
    |> case do
      {:ok, values} -> {:ok, Enum.reverse(values)}
      error -> error
    end
  end

  # @cc [owner:ghuntley,label:security;capacity] report-inventory-authority-only
  # Inventory MUST accept only exact architecture, image and execution-readiness
  # facts. Decorative inventory and diagnostics MUST fail before persistence.
  @spec inventory?(term()) :: boolean()
  defp inventory?(
         %{
           "architecture" => "x86_64",
           "images" => images,
           "execution_ready" => ready,
           "terminal_protocol" => terminal,
           "inception_image_id" => inception,
           "checkpoint_image_ids" => checkpoint_image_ids,
           "checkpoint_compatibility" => compatibility
         } = inventory
       ) do
    map_size(inventory) == 7 and
      OverallsProtocol.NativeAdmission.checkpoint_image_ids?(checkpoint_image_ids) and
      (is_nil(compatibility) or OverallsProtocol.ImageManifest.id?(compatibility)) and
      OverallsProtocol.ImageManifest.ids?(images) and
      is_boolean(ready) and terminal in [0, 2] and
      (is_nil(inception) or OverallsProtocol.ImageManifest.id?(inception))
  end

  defp inventory?(_), do: false
  defp positive?(n), do: is_integer(n) and n > 0 and n <= @max_integer
  defp non_negative?(n), do: is_integer(n) and n >= 0 and n <= @max_integer
end
