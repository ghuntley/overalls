defmodule Overalls.HegelFixtures do
  @moduledoc "Per-case supervised fixture ownership for Hegel properties."

  # @cc [owner:ghuntley,label:verification] hegel-supervised-fixture-custody
  # Case cleanup MUST stop and delete its own supervised child, including on
  # failure or replay. A reused child ID MUST NOT authorize stopping a different
  # PID. Explicit earlier teardown is allowed, as is the child exiting on its own
  # between inspection and termination; other cleanup failures MUST fail.
  @spec start_supervised!(Supervisor.child_spec() | {module(), term()} | module(), keyword()) ::
          pid()
  def start_supervised!(child, options \\ []) do
    _ = :hegel.current_test_case()
    spec = Supervisor.child_spec(child, options)
    pid = ExUnit.Callbacks.start_supervised!(spec)
    {:ok, supervisor} = ExUnit.fetch_test_supervisor()

    Hegel.on_cleanup(fn -> cleanup(supervisor, spec.id, pid) end)
    pid
  end

  @doc "Uses case cleanup inside Hegel and ordinary test ownership in ExUnit setup."
  @spec start_fixture!(Supervisor.child_spec() | {module(), term()} | module(), keyword()) ::
          pid()
  def start_fixture!(child, options \\ []) do
    if Hegel.in_property_case?(),
      do: start_supervised!(child, options),
      else: ExUnit.Callbacks.start_supervised!(child, options)
  end

  @spec cleanup(pid(), term(), pid()) :: :ok
  defp cleanup(supervisor, id, expected) do
    case List.keyfind(Supervisor.which_children(supervisor), id, 0) do
      nil ->
        :ok

      {^id, ^expected, _, _} ->
        case Supervisor.terminate_child(supervisor, id) do
          :ok ->
            # Temporary children remove their specification as part of termination.
            case Supervisor.delete_child(supervisor, id) do
              :ok -> :ok
              {:error, :not_found} -> :ok
              other -> raise "Hegel fixture specification cleanup failed: #{inspect(other)}"
            end

          # The child exited after which_children/1 and, being temporary, the
          # supervisor already removed it; nothing of another PID was touched.
          {:error, :not_found} ->
            :ok
        end

      {^id, :undefined, _, _} ->
        :ok = Supervisor.delete_child(supervisor, id)

      {^id, _, _, _} ->
        raise "Hegel fixture child ID belongs to a different process"
    end
  end
end
