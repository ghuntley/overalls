defmodule Marshall.Agents.ExecutorRPC do
  @moduledoc "Host-authenticated, VM-bound wire boundary for guest executor RPCs."
  alias Marshall.Agents.{Bootstrap, ExecutorSession, Maintenance}
  alias Marshall.Compute.Ledger
  alias Marshall.Inference.Credentials

  @maintenance_routes ~w(maintenance_claim maintenance_transition maintenance_artifact bootstrap_artifact)
  @routes ~w(register heartbeat claim transition attachment_upload attachment_transfer artifact_chunk) ++
            @maintenance_routes

  # @cc [owner:ghuntley,label:security;recovery] executor-rpc-host-binding
  # The dedicated Ziggy credential MUST authenticate the binding's physical
  # host under the same transaction as the VM and lease checks. Only Audi's
  # pre-NAT binding, relayed by Ziggy, may select the VM. Wire responses MUST
  # expose no credential, prompt, or unrelated VM state.
  @spec request(binary(), binary(), term()) :: {:ok, map()} | {:error, term()}
  def request(token, route, input) when route in @routes and is_map(input) do
    with {:ok, binding} <- parse_binding(input),
         {:ok, operation} <- operation(route, input) do
      :ok = verify_releases_before_locks(route)

      Ledger.transaction(
        fn ->
          authority = Credentials.authenticate_locked!(token)
          unless authority.host_id == binding.host_id, do: Ledger.rollback(:unauthorized)

          if route in @maintenance_routes or
               (route == "claim" and Bootstrap.requires_authority?(input["executor_id"])) or
               (route == "transition" and Bootstrap.attempt?(input["command_id"])) do
            unwrap!(Marshall.Inference.Requests.authorize(token, input["binding"]))
          end

          execute!(operation, input["binding"])
        end,
        {:provisioner, binding.host_id}
      )
    end
  end

  def request(_, _, _), do: {:error, :invalid_request}

  # @cc [owner:ghuntley,label:concurrency;recovery] executor-release-verification-before-locks
  # Routes that may read the GitHub tool or executor bootstrap release MUST
  # complete that release's artifact size and SHA256 verification before the
  # request transaction takes host credential or VM row locks. A cold release
  # cache MUST NOT hold the executor's VM lock while large artifacts are hashed,
  # because roster, SSH and inference authority for the same VM wait on that
  # lock. This only warms the validated cache: the in-transaction loads still
  # decide the response, and a failed verification still fails closed there.
  @spec verify_releases_before_locks(String.t()) :: :ok
  defp verify_releases_before_locks(route)
       when route in @maintenance_routes or route in ["claim", "transition"] do
    _ = Marshall.Operations.GitHubTools.load()
    _ = Marshall.Operations.ExecutorBootstrap.load()
    :ok
  end

  defp verify_releases_before_locks(_route), do: :ok

  defp parse_binding(%{"binding" => wire}) when is_map(wire),
    do: OverallsProtocol.PrivateServices.binding(wire)

  defp parse_binding(_), do: {:error, :invalid_request}

  defp operation("register", %{"binding" => _} = input) do
    capabilities = Map.get(input, "capabilities", [])
    digest = Map.get(input, "digest")

    with [] <- Map.keys(input) -- ~w(binding digest capabilities),
         true <- not Map.has_key?(input, "digest") or valid_digest?(digest),
         true <- ExecutorSession.valid_capabilities?(capabilities) do
      {:ok, {:register, digest, capabilities}}
    else
      _ -> {:error, :invalid_request}
    end
  end

  defp operation("heartbeat", input), do: lease_operation(:heartbeat, input)
  defp operation("claim", input), do: lease_operation(:claim, input)
  defp operation("maintenance_claim", input), do: lease_operation(:maintenance_claim, input)

  defp operation(
         "maintenance_transition",
         %{
           "binding" => _,
           "executor_id" => executor_id,
           "fence_epoch" => fence,
           "maintenance_id" => id,
           "status" => status,
           "result" => result
         } = input
       )
       when map_size(input) == 6 and is_integer(fence) and fence > 0 and
              status in ["started", "completed", "failed"] and is_map(result) do
    if OverallsProtocol.uuid?(executor_id) and OverallsProtocol.uuid?(id),
      do: {:ok, {:maintenance_transition, executor_id, fence, id, status, result}},
      else: {:error, :invalid_request}
  end

  defp operation(
         "maintenance_artifact",
         %{
           "binding" => _,
           "executor_id" => executor_id,
           "fence_epoch" => fence,
           "maintenance_id" => id,
           "digest" => digest
         } = input
       )
       when map_size(input) == 5 and is_integer(fence) and fence > 0 do
    if OverallsProtocol.uuid?(executor_id) and OverallsProtocol.uuid?(id) and
         OverallsProtocol.GitHubTools.digest?(digest),
       do: {:ok, {:maintenance_artifact, executor_id, fence, id, digest}},
       else: {:error, :invalid_request}
  end

  defp operation(
         "bootstrap_artifact",
         %{
           "binding" => _,
           "executor_id" => executor_id,
           "fence_epoch" => fence,
           "bootstrap_id" => id,
           "digest" => digest
         } = input
       )
       when map_size(input) == 5 and is_integer(fence) and fence > 0 do
    if OverallsProtocol.uuid?(executor_id) and OverallsProtocol.uuid?(id) and
         OverallsProtocol.GitHubTools.digest?(digest),
       do: {:ok, {:bootstrap_artifact, executor_id, fence, id, digest}},
       else: {:error, :invalid_request}
  end

  defp operation(
         "transition",
         %{
           "binding" => _,
           "executor_id" => executor_id,
           "fence_epoch" => fence,
           "command_id" => command_id,
           "status" => status
         } = input
       )
       when map_size(input) in [5, 6] and is_integer(fence) and fence > 0 do
    result = Map.get(input, "result", %{})

    with true <- OverallsProtocol.uuid?(executor_id) and OverallsProtocol.uuid?(command_id),
         true <- is_map(result),
         true <- exact_transition_keys?(input),
         {:ok, state} <- state(status) do
      {:ok, {:transition, executor_id, fence, command_id, state, result}}
    else
      _ -> {:error, :invalid_request}
    end
  end

  # @cc [owner:ghuntley,label:security] executor-upload-wire-bound
  # Upload transport MUST accept only the exact lease/command selectors and a
  # bounded base64 body. Decoded content MUST NOT exceed the attachment limit.
  defp operation(
         "attachment_upload",
         %{
           "binding" => _,
           "executor_id" => id,
           "fence_epoch" => fence,
           "command_id" => command_id,
           "content_base64" => content
         } = input
       )
       when map_size(input) == 5 and is_integer(fence) and fence > 0 and
              is_binary(content) and byte_size(content) <= 13_981_016 do
    with true <- OverallsProtocol.uuid?(id) and OverallsProtocol.uuid?(command_id),
         {:ok, bytes} <- Base.decode64(content),
         true <- byte_size(bytes) <= 10 * 1024 * 1024 do
      {:ok, {:attachment_upload, id, fence, command_id, bytes}}
    else
      _ -> {:error, :invalid_request}
    end
  end

  defp operation(
         "attachment_transfer",
         %{
           "binding" => _,
           "executor_id" => id,
           "fence_epoch" => fence,
           "command_id" => command_id,
           "transfer" => transfer
         } = input
       )
       when map_size(input) == 5 and is_integer(fence) and fence > 0 do
    with true <- OverallsProtocol.uuid?(id) and OverallsProtocol.uuid?(command_id),
         {:ok, parsed} <- parse_transfer(transfer) do
      {:ok, {:attachment_transfer, id, fence, command_id, parsed}}
    else
      _ -> {:error, :invalid_request}
    end
  end

  defp operation(
         "artifact_chunk",
         %{
           "binding" => _,
           "executor_id" => executor_id,
           "fence_epoch" => fence,
           "command_id" => command_id,
           "publish_request_id" => request_id,
           "file_index" => file_index,
           "chunk_index" => chunk_index,
           "sha256" => sha,
           "data" => data
         } = input
       )
       when map_size(input) == 9 and is_integer(fence) and fence > 0 and
              is_integer(file_index) and file_index in 0..254 and is_integer(chunk_index) and
              chunk_index >= 0 and is_binary(data) do
    with true <- Enum.all?([executor_id, command_id, request_id], &OverallsProtocol.uuid?/1),
         true <- valid_digest?(sha),
         {:ok, bytes} <- Base.decode64(data),
         true <- byte_size(bytes) in 1..Marshall.Artifacts.Staging.chunk_bytes(),
         true <- Marshall.Artifacts.Blobs.sha256(bytes) == sha do
      {:ok,
       {:artifact_chunk, executor_id, fence, command_id,
        %{
          publish_request_id: request_id,
          file_index: file_index,
          chunk_index: chunk_index,
          sha256: sha,
          data: bytes
        }}}
    else
      _ -> {:error, :invalid_request}
    end
  end

  defp operation(_, _), do: {:error, :invalid_request}

  @spec parse_transfer(term()) ::
          {:ok, ExecutorSession.attachment_transfer()} | {:error, :invalid_request}
  defp parse_transfer(%{"phase" => "begin", "size_bytes" => size, "sha256" => sha} = input)
       when map_size(input) == 3 and is_integer(size) and size in 0..10_485_760 do
    if valid_digest?(sha), do: {:ok, {:begin, size, sha}}, else: {:error, :invalid_request}
  end

  defp parse_transfer(
         %{
           "phase" => "chunk",
           "attachment_id" => id,
           "offset" => offset,
           "content_base64" => content
         } = input
       )
       when map_size(input) == 4 and is_integer(offset) and offset >= 0 and
              is_binary(content) and byte_size(content) <= 349_528 do
    with true <- OverallsProtocol.uuid?(id),
         {:ok, bytes} <- Base.decode64(content),
         true <- byte_size(bytes) in 1..262_144 do
      {:ok, {:chunk, id, offset, bytes}}
    else
      _ -> {:error, :invalid_request}
    end
  end

  defp parse_transfer(%{"phase" => "finish", "attachment_id" => id} = input)
       when map_size(input) == 2 do
    if OverallsProtocol.uuid?(id), do: {:ok, {:finish, id}}, else: {:error, :invalid_request}
  end

  defp parse_transfer(%{"phase" => "read", "offset" => offset} = input)
       when map_size(input) == 2 and is_integer(offset) and offset >= 0,
       do: {:ok, {:read, offset}}

  defp parse_transfer(_), do: {:error, :invalid_request}

  defp exact_transition_keys?(input) do
    required = ~w(binding command_id executor_id fence_epoch status)
    expected = if Map.has_key?(input, "result"), do: ["result" | required], else: required
    Enum.sort(Map.keys(input)) == Enum.sort(expected)
  end

  defp lease_operation(
         kind,
         %{
           "binding" => _,
           "executor_id" => executor_id,
           "fence_epoch" => fence
         } = input
       )
       when map_size(input) == 3 and is_integer(fence) and fence > 0 do
    if OverallsProtocol.uuid?(executor_id),
      do: {:ok, {kind, executor_id, fence}},
      else: {:error, :invalid_request}
  end

  defp lease_operation(_, _), do: {:error, :invalid_request}

  defp state("started"), do: {:ok, :started}
  defp state("completed"), do: {:ok, :completed}
  defp state("failed"), do: {:ok, :failed}
  defp state("uncertain"), do: {:ok, :uncertain}
  defp state(_), do: {:error, :invalid_request}

  @spec valid_digest?(term()) :: boolean()
  defp valid_digest?(digest) when is_binary(digest),
    do: Regex.match?(~r/\A[0-9a-f]{64}\z/, digest)

  defp valid_digest?(_), do: false

  defp execute!({:register, digest, capabilities}, binding) do
    executor = unwrap!(ExecutorSession.register(binding, digest, capabilities))

    %{
      executor_id: executor.id,
      fence_epoch: executor.fence_epoch,
      expires_at_ms: DateTime.to_unix(executor.expires_at, :millisecond)
    }
  end

  defp execute!({:attachment_transfer, id, fence, command_id, transfer}, binding) do
    unwrap!(ExecutorSession.attachment_transfer(binding, id, fence, command_id, transfer))
  end

  defp execute!({:attachment_upload, id, fence, command_id, bytes}, binding) do
    unwrap!(ExecutorSession.attachment_upload(binding, id, fence, command_id, bytes))
  end

  defp execute!({:heartbeat, id, fence}, binding) do
    executor = unwrap!(ExecutorSession.heartbeat(binding, id, fence))
    %{expires_at_ms: DateTime.to_unix(executor.expires_at, :millisecond)}
  end

  defp execute!({:claim, id, fence}, binding) do
    parsed = unwrap!(OverallsProtocol.PrivateServices.binding(binding))

    candidate =
      Bootstrap.claim_locked!(parsed, id, fence) ||
        unwrap!(ExecutorSession.claim(binding, id, fence))

    case candidate do
      nil ->
        %{command: nil}

      command ->
        %{
          command: %{
            id: command.id,
            call_id: command.call_id,
            tool: command.tool,
            arguments: command.arguments
          }
        }
    end
  end

  defp execute!({:transition, id, fence, command_id, state, result}, binding) do
    parsed = unwrap!(OverallsProtocol.PrivateServices.binding(binding))

    case Bootstrap.transition_locked!(parsed, id, fence, command_id, state, result) do
      {:ok, response} ->
        response

      :not_bootstrap ->
        command =
          unwrap!(ExecutorSession.transition(binding, id, fence, command_id, state, result))

        %{command_id: command.id, status: command.status}
    end
  end

  defp execute!({:maintenance_claim, id, fence}, binding) do
    parsed = unwrap!(OverallsProtocol.PrivateServices.binding(binding))
    release = unwrap!(Marshall.Operations.GitHubTools.load())
    Maintenance.claim_locked!(parsed, id, fence, release)
  end

  defp execute!({:maintenance_transition, id, fence, attempt_id, status, result}, binding) do
    parsed = unwrap!(OverallsProtocol.PrivateServices.binding(binding))
    release = unwrap!(Marshall.Operations.GitHubTools.load())
    Maintenance.transition_locked!(parsed, id, fence, attempt_id, status, result, release)
  end

  defp execute!({:maintenance_artifact, id, fence, attempt_id, digest}, binding) do
    parsed = unwrap!(OverallsProtocol.PrivateServices.binding(binding))
    release = unwrap!(Marshall.Operations.GitHubTools.load())
    Maintenance.artifact_locked!(parsed, id, fence, attempt_id, digest, release)
  end

  defp execute!({:bootstrap_artifact, id, fence, attempt_id, digest}, binding) do
    parsed = unwrap!(OverallsProtocol.PrivateServices.binding(binding))
    Bootstrap.artifact_locked!(parsed, id, fence, attempt_id, digest)
  end

  defp execute!({:artifact_chunk, id, fence, command_id, chunk}, binding) do
    parsed = unwrap!(OverallsProtocol.PrivateServices.binding(binding))

    command =
      ExecutorSession.started_command_locked!(parsed, id, fence, command_id, :artifact_stage)

    Marshall.Artifacts.Staging.receive_chunk_locked!(command, chunk)
    %{accepted: true}
  end

  defp unwrap!({:ok, value}), do: value
  defp unwrap!({:error, reason}) when is_atom(reason), do: Ledger.rollback(reason)
  defp unwrap!(_), do: Ledger.rollback(:unavailable)
end
