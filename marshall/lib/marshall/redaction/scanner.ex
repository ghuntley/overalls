defmodule Marshall.Redaction.Scanner do
  @moduledoc "Typed, text-only secret scanner used at ingress and during historical scrubs."

  @type finding :: %{rule: String.t(), count: non_neg_integer()}
  @type result :: %{value: String.t(), findings: [finding()]}

  @profile_source Path.expand("../../../priv/redaction/profile.json", __DIR__)
  @external_resource @profile_source
  @profile_bytes File.read!(@profile_source)
  @profile_digest :crypto.hash(:sha256, @profile_bytes) |> Base.encode16(case: :lower)
  @compiled_rules @profile_bytes
                  |> Jason.decode!()
                  |> Map.fetch!("rules")
                  |> Enum.flat_map(fn %{"id" => id, "pattern" => pattern} ->
                    case Regex.compile(pattern, "s") do
                      {:ok, regex} -> [{id, regex}]
                      {:error, _} -> []
                    end
                  end)

  @spec profile_digest() :: String.t()
  def profile_digest, do: @profile_digest

  @spec redact(String.t()) :: result()
  def redact(value) when is_binary(value) do
    {redacted, counts} =
      Enum.reduce(rules(), {value, %{}}, fn {rule, regex}, {text, found} ->
        count = length(Regex.scan(regex, text))
        next = Regex.replace(regex, text, "[REDACTED:#{rule}]")
        {next, if(count == 0, do: found, else: Map.update(found, rule, count, &(&1 + count)))}
      end)

    %{
      value: redacted,
      findings: Enum.map(counts, fn {rule, count} -> %{rule: rule, count: count} end)
    }
  end

  @spec rules() :: [{String.t(), Regex.t()}]
  defp rules do
    case :persistent_term.get({__MODULE__, :rules}, :missing) do
      :missing ->
        loaded = @compiled_rules

        :persistent_term.put({__MODULE__, :rules}, loaded)
        loaded

      loaded ->
        loaded
    end
  end

  @spec redact_json(term()) :: {term(), [finding()]}
  def redact_json(value) when is_binary(value) do
    result = redact(value)
    {result.value, result.findings}
  end

  def redact_json(value) when is_list(value) do
    Enum.map_reduce(value, [], fn item, findings ->
      {redacted, nested} = redact_json(item)
      {redacted, findings ++ nested}
    end)
  end

  def redact_json(value) when is_map(value) do
    Enum.reduce(value, {%{}, []}, fn {key, item}, {result, findings} ->
      {redacted, nested} = redact_json(item)
      {Map.put(result, key, redacted), findings ++ nested}
    end)
  end

  def redact_json(value), do: {value, []}
end
