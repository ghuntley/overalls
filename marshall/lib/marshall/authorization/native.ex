defmodule Marshall.Authorization.Native do
  @moduledoc "Marshall's Cedar NIF (`native/marshall_cedar`); call only through `Marshall.Authorization.Cedar`."
  use Rustler, otp_app: :marshall, crate: "marshall_cedar", path: "native/marshall_cedar"

  @type reference_term :: {String.t(), String.t()}
  @type value ::
          boolean() | integer() | String.t() | reference_term() | [value()]
  @type entity_term :: {String.t(), String.t(), [{String.t(), value()}], [reference_term()]}

  @spec compile(String.t(), String.t()) :: {:ok, reference()} | {:error, [String.t()]}
  def compile(_policies, _schema), do: :erlang.nif_error(:nif_not_loaded)

  @spec authorize(reference(), [entity_term()], reference_term(), String.t(), reference_term()) ::
          boolean()
  def authorize(_engine, _entities, _principal, _action, _resource),
    do: :erlang.nif_error(:nif_not_loaded)

  @spec authorize_many(reference(), [entity_term()], reference_term(), String.t(), [
          reference_term()
        ]) :: [boolean()]
  def authorize_many(_engine, _entities, _principal, _action, _resources),
    do: :erlang.nif_error(:nif_not_loaded)

  @spec residuals(reference(), String.t(), String.t(), String.t()) ::
          {:allow | :deny | :residual, [String.t()]}
  def residuals(_engine, _principal_type, _action, _resource_type),
    do: :erlang.nif_error(:nif_not_loaded)
end
