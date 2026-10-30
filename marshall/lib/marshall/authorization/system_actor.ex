defmodule Marshall.Authorization.SystemActor do
  @moduledoc """
  A trusted in-process actor: the compute coordinator and its durable jobs, or
  a library service (AshAuthentication, SCIM provisioning) acting for itself.

  Never construct this actor from HTTP parameters, a socket payload or a claimed
  role. External provisioner identities must be authenticated separately, and
  the SCIM service actor is presented only after bearer authentication.
  """
  @enforce_keys [:purpose]
  defstruct [:purpose]
  @type service :: :ash_authentication | :scim
  @type t :: %__MODULE__{purpose: :compute | service()}

  @spec compute() :: t()
  def compute, do: %__MODULE__{purpose: :compute}

  @spec service(service()) :: t()
  def service(service) when service in [:ash_authentication, :scim],
    do: %__MODULE__{purpose: service}
end
