defmodule Marshall.Authorization.FilterTranslationTest do
  use Marshall.DataCase, async: false
  import ExUnit.CaptureLog
  import Marshall.ComputeFixtures

  alias Marshall.Authorization.Filter

  # Every record action the schema applies to a SQL-backed entity type.
  @records %{
    Marshall.Compute.VirtualMachine.Cedar => ~w(read write manage web),
    Marshall.Threads.Thread.Cedar => ~w(read write manage),
    Marshall.Teams.Team.Cedar => ~w(team_read team_manage_members team_transfer),
    Marshall.Galileo.Integration.Cedar => ~w(integration_read integration_manage),
    Marshall.Terminal.Session.Cedar => ~w(terminal_session_use),
    Marshall.Artifacts.Artifact.Cedar =>
      ~w(artifact_read artifact_publish artifact_share artifact_delete
         artifact_storage_personal artifact_storage_shared_read artifact_storage_shared_write)
  }

  # @cc [owner:ghuntley,label:security] cedar-filter-production-translation
  # Every residual the production policy leaves for a user principal on a
  # SQL-backed record action MUST translate into a row filter. A residual that
  # falls back to the fail-closed `false` would silently deny every owner.
  test "every production record residual translates for a user principal" do
    principal = user()

    log =
      capture_log(fn ->
        for {record, actions} <- @records, action <- actions do
          refute Filter.expression(principal, action, record) == false,
                 "#{inspect(record)} #{action}"
        end
      end)

    refute log =~ "cedar.filter_unsupported"
  end

  test "an administrator-only action leaves no row filter for an ordinary user" do
    refute Filter.expression(user(), "artifact_admin_delete", Marshall.Artifacts.Artifact.Cedar)
  end

  test "an unknown principal is denied every row" do
    for {record, [action | _]} <- @records,
        do: assert(Filter.expression(%{id: Ash.UUID.generate()}, action, record) == false)
  end
end
