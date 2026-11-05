defmodule Ziggy.AgentError do
  @moduledoc "Closed provider rejection classes for Marshall-owned model calls."

  @type reason ::
          :context_length_exceeded
          | :unsupported_compaction
          | :incomplete
          | :cancelled
          | :upstream_failed

  # @cc [owner:ghuntley,label:security;recovery] agent-error-closed-classification
  # Only closed codes, statuses and the exact compaction parameter may identify
  # a provider rejection. Free-form messages MUST NOT become a reason or leave
  # this boundary. An unrecognized rejection MUST remain upstream_failed.
  @spec classify(term()) :: reason()
  def classify(%{"status" => "incomplete"}), do: :incomplete
  def classify(%{"status" => status}) when status in ["cancelled", "canceled"], do: :cancelled
  def classify(%{"error" => error}), do: classify(error)

  def classify(%{"code" => code, "param" => "compaction_trigger"})
      when code in ["unknown_parameter", "unsupported_parameter", "unsupported_value"],
      do: :unsupported_compaction

  def classify(%{"code" => code}) when is_binary(code), do: classify(code)
  def classify(%{"type" => type}), do: classify(type)

  def classify(code) when code in ["context_length_exceeded", "context_window_exceeded"],
    do: :context_length_exceeded

  def classify("unsupported_compaction"), do: :unsupported_compaction
  def classify("incomplete"), do: :incomplete
  def classify(code) when code in ["cancelled", "canceled"], do: :cancelled
  def classify(_), do: :upstream_failed

  @spec terminal(map()) :: reason() | nil
  def terminal(%{"status" => "incomplete"}), do: :incomplete
  def terminal(%{"status" => status}) when status in ["cancelled", "canceled"], do: :cancelled
  def terminal(%{"status" => "failed"} = response), do: classify(response)
  def terminal(%{"error" => error}) when not is_nil(error), do: classify(error)
  def terminal(_), do: nil
end
