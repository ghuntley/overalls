defmodule Porsche.SSH.Output do
  @moduledoc "Single-result channel output, separate from bounded progress messages."
  use Gettext, backend: Porsche.Gettext

  # @cc [owner:ghuntley,label:security;protocol] porsche-terminal-result-framing
  # JSON output MUST decode to the original response as one newline-terminated
  # object. Peer-provided control characters MUST be escaped in both output
  # modes, including nested strings and Unicode C1/line-separator controls.
  @spec render(map(), boolean()) :: binary()
  def render(response, true), do: encode(response) <> "\n"

  def render(%{"result" => %{"commands" => commands}} = response, false) when is_list(commands) do
    rows =
      for %{"usage" => usage, "summary" => summary} <- commands,
          is_binary(usage) and is_binary(summary),
          do: safe(usage) <> "\n  " <> safe(Gettext.dgettext(Porsche.Gettext, "help", summary))

    if rows == [], do: human(response), else: Enum.join(rows, "\n") <> "\n"
  end

  def render(
        %{"status" => "approval_required", "fingerprint" => fingerprint, "approval_url" => url},
        false
      )
      when is_binary(fingerprint) and is_binary(url),
      do: Porsche.SSH.Onboarding.approval(fingerprint, url)

  def render(%{"status" => "error", "error" => reason}, false) when is_binary(reason),
    do: error_message(reason) <> "\n"

  def render(response, false), do: human(response)

  # @cc [owner:ghuntley,label:security;protocol] porsche-exec-approval-lifetime
  # Human exec rejections MUST direct users to a live interactive connection,
  # not display a link invalidated by that exec's disconnect. JSON framing and
  # pending approval data MUST remain unchanged for multiplexed clients.
  @spec render(map(), boolean(), :interactive | {:exec, binary()}) :: binary()
  def render(
        %{"status" => "approval_required", "fingerprint" => fingerprint},
        false,
        {:exec, origin}
      )
      when is_binary(fingerprint),
      do: Porsche.SSH.Onboarding.retry_interactively(fingerprint, origin)

  def render(response, json, _context), do: render(response, json)

  @spec error_message(String.t()) :: String.t()
  defp error_message(reason) do
    case reason do
      "unauthorized" ->
        dgettext("management", "This connection is not authorized. Please sign in and try again.")

      "forbidden" ->
        dgettext("management", "You do not have permission to perform this action.")

      "invalid_command" ->
        dgettext("management", "Invalid command. Type help to see available commands.")

      "temporarily_unavailable" ->
        dgettext(
          "management",
          "The service is temporarily unavailable. Please try again shortly."
        )

      "approval_required" ->
        dgettext("management", "Approve this SSH key in your browser, then retry the command.")

      "not_found" ->
        dgettext("management", "The requested resource could not be found.")

      "unexpected_input" ->
        dgettext("management", "Unexpected input. Please open a new SSH connection.")

      "machine_pinned" ->
        dgettext("management", "The owner has this machine pinned; unpin it first: unpin MACHINE")

      "machine_failed" ->
        dgettext(
          "management",
          "A failed machine cannot be pinned; an existing pin can still be removed."
        )

      "pin_limit" ->
        dgettext("management", "You already hold the maximum number of pins; unpin one first.")

      "insufficient_capacity" ->
        dgettext("management", "There is not enough available capacity for this request.")

      "host_unavailable" ->
        dgettext("management", "The machine's host is unavailable. Please try again shortly.")

      "clone_already_published" ->
        dgettext(
          "management",
          "This clone has already been published and cannot be retried or cancelled."
        )

      "clone_not_retryable" ->
        dgettext("management", "This clone request cannot be retried in its current state.")

      "clone_in_progress" ->
        dgettext("management", "A clone request is already in progress for this machine.")

      "idempotency_conflict" ->
        dgettext(
          "management",
          "This request ID was already used for a different command. Use the original command or a new request ID."
        )

      "workload_not_stable" ->
        dgettext(
          "management",
          "The machine's workload is not stable enough for this operation. Check its state before retrying."
        )

      "checkpoint_unavailable" ->
        dgettext(
          "management",
          "Checkpoints are unavailable for this machine on its host. Stop the machine instead of pausing it."
        )

      "vm_busy" ->
        dgettext(
          "management",
          "The machine is busy with another operation. Try again after it finishes."
        )

      "source_unavailable" ->
        dgettext("management", "The source machine is unavailable for this operation.")

      "transfer_busy" ->
        dgettext(
          "management",
          "A transfer is already using this host's transfer slot. Please try again after it finishes."
        )

      "source_cleanup_pending" ->
        dgettext(
          "management",
          "Source cleanup is still pending. Wait for cleanup before retrying."
        )

      "resize_in_progress" ->
        dgettext("management", "A resize request is already in progress for this machine.")

      "relocation_in_progress" ->
        dgettext("management", "A relocation is already in progress for this machine.")

      "relocation_committed" ->
        dgettext(
          "management",
          "This relocation has committed its handoff and can no longer be cancelled."
        )

      "relocation_finished" ->
        dgettext("management", "This relocation has already finished.")

      "relocation_retry_unavailable" ->
        dgettext("management", "This relocation cannot be retried in its current state.")

      "placement_changed" ->
        dgettext(
          "management",
          "The machine's placement has changed. Inspect its current state before retrying."
        )

      "name_unavailable" ->
        dgettext("management", "This machine name is unavailable. Choose another name.")

      "invalid_request" ->
        dgettext("management", "The request is invalid. Check the command and its arguments.")

      "conflict" ->
        dgettext(
          "management",
          "The request conflicts with the current state. Inspect the machine or request before retrying."
        )

      "message_too_large" ->
        dgettext("management", "The request or response exceeds the permitted size.")

      "rate_limited" ->
        dgettext(
          "management",
          "Too many sessions or approval requests are active. Close an unused connection and try again."
        )

      "unsupported_version" ->
        dgettext(
          "management",
          "The service does not support this protocol version. Ask your operator to update the compatible services."
        )

      "transport_error" ->
        dgettext(
          "management",
          "The connection to the control service was interrupted. Check the request status before submitting it again."
        )

      "invalid_response" ->
        dgettext(
          "management",
          "The control service returned an invalid response. Check the request status before submitting it again."
        )

      "http_error" ->
        dgettext(
          "management",
          "The control service refused the request. Check the request status before submitting it again."
        )

      "invalid_configuration" ->
        dgettext("management", "The service configuration is invalid. Contact your operator.")

      "vm_deleted" ->
        dgettext("management", "This machine has been deleted.")

      "image_unavailable" ->
        dgettext("management", "The requested machine image is unavailable.")

      "image_requirements_not_met" ->
        dgettext(
          "management",
          "The available host does not meet the machine image's requirements."
        )

      "invalid_vm_size" ->
        dgettext(
          "management",
          "The requested machine size is invalid. Check the CPU, memory and disk limits."
        )

      "disk_not_reserved" ->
        dgettext("management", "The machine's disk is not reserved for this operation.")

      "generation_exhausted" ->
        dgettext(
          "management",
          "This machine has reached its execution generation limit. Contact your operator."
        )

      "owner_protected" ->
        dgettext("management", "This action cannot remove the owner's protected access.")

      "recipient_not_registered" ->
        dgettext("management", "The recipient does not have a registered account.")

      "workspace_source_not_allowed" ->
        dgettext("management", "A repository source is not allowed for this machine profile.")

      "workspace_source_unavailable" ->
        dgettext("management", "The repository source is unavailable.")

      "invalid_workspace_source" ->
        dgettext(
          "management",
          "The repository source is invalid. Use a supported public repository URL."
        )

      "resize_not_retryable" ->
        dgettext("management", "This resize request cannot be retried in its current state.")

      "resize_not_cancellable" ->
        dgettext("management", "This resize request cannot be cancelled in its current state.")

      "stop_unconfirmed" ->
        dgettext(
          "management",
          "The machine's stop has not been confirmed. Inspect its state before retrying."
        )

      "stale_generation" ->
        dgettext(
          "management",
          "The machine's execution generation has changed. Inspect its current state before retrying."
        )

      "request_not_found" ->
        dgettext("management", "The requested command receipt could not be found.")

      "key_not_found" ->
        dgettext("management", "The requested SSH key could not be found.")

      "https_required" ->
        dgettext("management", "This connection requires verified HTTPS. Contact your operator.")

      "session_limit" ->
        dgettext(
          "management",
          "The session limit has been reached. Close an unused connection and try again."
        )

      "approval_limit" ->
        dgettext(
          "management",
          "The approval request limit has been reached. Close an unused connection and try again."
        )

      "invalid_public_key" ->
        dgettext("management", "The SSH public key is invalid. Check the key and try again.")

      "attach_requires_pty" ->
        dgettext(
          "management",
          "terminal attach needs a terminal. Connect with ssh -t and run it as the command."
        )

      "thread_not_ready" ->
        dgettext("management", "This thread is not ready for prompts yet.")

      "thread_busy" ->
        dgettext("management", "This thread is busy with a turn. Try again when it finishes.")

      "stale_proposal" ->
        dgettext(
          "management",
          "That plan is no longer the latest proposal. Show the thread again."
        )

      "stale_question" ->
        dgettext("management", "That question is no longer pending.")

      "already_answered" ->
        dgettext("management", "That question has already been answered.")

      "invalid_answers" ->
        dgettext("management", "The answers do not match the pending question.")

      "awaiting_answers" ->
        dgettext("management", "Answer the pending question before sending another prompt.")

      "revision_conflict" ->
        dgettext(
          "management",
          "The web settings changed since you read them. Show them again and retry."
        )

      "reserved_editor_port" ->
        dgettext("management", "Port 4444 is reserved for the editor.")

      "web_not_allowed" ->
        dgettext("management", "This machine's profile does not allow web publishing.")

      "terminal_unavailable" ->
        dgettext("management", "Terminals are unavailable on this machine right now.")

      "terminal_open_pending" ->
        dgettext("management", "The machine is waking. Retry the terminal shortly.")

      "unknown_session" ->
        dgettext("management", "That terminal session no longer exists.")

      "push_disabled" ->
        dgettext(
          "management",
          "This deployment has push notifications turned off; ask its operator."
        )

      "device_limit" ->
        dgettext(
          "management",
          "You already have the maximum number of devices; remove one first: device rm DEVICE_ID"
        )

      "stdin_payload_required" ->
        dgettext(
          "management",
          "This command reads its input from standard input. Pipe it in and end the command with -."
        )

      "stdin_payload_invalid" ->
        dgettext(
          "management",
          "The standard input is empty or exceeds this command's size limit."
        )

      _ ->
        dgettext("management", "The command could not be completed: %{reason}",
          reason: safe(reason)
        )
    end
  end

  # @cc [owner:ghuntley,label:product;protocol] porsche-human-localization-boundary
  # Human rendering MUST translate only reviewed outer labels and receipt statuses.
  # Unknown keys, identifiers and nested result values MUST remain literal and
  # escaped. The JSON rendering branch MUST remain independent of locale.
  @spec human(map()) :: binary()
  defp human(response) do
    response
    |> Enum.sort()
    |> Enum.map_join("\n", fn {key, value} -> label(key) <> ": " <> field_value(key, value) end)
    |> Kernel.<>("\n")
  end

  @spec label(String.t()) :: String.t()
  defp label("version"), do: dgettext("management", "Protocol version")
  defp label("status"), do: dgettext("management", "Status")
  defp label("request_id"), do: dgettext("management", "Request ID")
  defp label("operation_id"), do: dgettext("management", "Operation ID")
  defp label("result"), do: dgettext("management", "Result")
  defp label(key), do: safe(key)

  @spec field_value(String.t(), term()) :: String.t()
  defp field_value("status", "accepted"), do: dgettext("management", "Accepted")
  defp field_value("status", "succeeded"), do: dgettext("management", "Succeeded")
  defp field_value("status", "failed"), do: dgettext("management", "Failed")
  defp field_value("status", "superseded"), do: dgettext("management", "Superseded")
  defp field_value(_key, value), do: value(value)

  @spec value(term()) :: String.t()
  defp value(text) when is_binary(text), do: safe(text)
  defp value(value), do: encode(value)

  defp encode(value) do
    value
    |> JSON.encode!()
    |> String.replace(
      ~r/[\x{007f}-\x{009f}\x{2028}\x{2029}]/u,
      fn <<point::utf8>> -> "\\u" <> String.pad_leading(Integer.to_string(point, 16), 4, "0") end
    )
  end

  defp safe(text) do
    String.replace(text, ~r/[\x{0000}-\x{001f}\x{007f}-\x{009f}\x{2028}\x{2029}]/u, fn control ->
      control |> encode() |> String.slice(1..-2//1)
    end)
  end

  @spec progress(map()) :: binary()
  def progress(%{event: :submitting, request_id: id}),
    do: dgettext("management", "Request %{id}: submitting", id: safe(id)) <> "\n"

  def progress(%{event: :waiting, request_id: id}),
    do: dgettext("management", "Request %{id}: waiting for completion", id: safe(id)) <> "\n"
end
