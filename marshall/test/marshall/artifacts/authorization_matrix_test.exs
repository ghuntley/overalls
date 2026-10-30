defmodule Marshall.Artifacts.AuthorizationMatrixTest do
  # @cc [owner:ghuntley,label:security;verification] artifact-authorization-matrix
  # Every principal kind × artifact action × artifact state MUST match the
  # pure role table: owners/co-owners hold every content action, writers read,
  # publish and use all storage, viewers read and use personal/shared-read
  # storage, strangers hold nothing, inactive artifacts deny content actions and
  # only elevated administrators may moderate, never read.
  use Marshall.DataCase, async: false

  alias Marshall.Authorization.Cedar
  alias Marshall.PasskeyFixture

  @content ~w(artifact_read artifact_publish artifact_share artifact_delete
              artifact_storage_personal artifact_storage_shared_read
              artifact_storage_shared_write)
  @actions @content ++ ["artifact_admin_delete"]

  @table %{
    owner: @content,
    co_owner: @content,
    writer: ~w(artifact_read artifact_publish artifact_storage_personal
         artifact_storage_shared_read artifact_storage_shared_write),
    viewer: ~w(artifact_read artifact_storage_personal artifact_storage_shared_read),
    stranger: [],
    admin_unelevated: [],
    admin_elevated: ["artifact_admin_delete"]
  }

  test "every principal, action and state matches the role table" do
    owner = PasskeyFixture.user(false)

    users = %{
      owner: owner,
      co_owner: PasskeyFixture.user(false),
      writer: PasskeyFixture.user(false),
      viewer: PasskeyFixture.user(false),
      stranger: PasskeyFixture.user(false),
      admin_unelevated: PasskeyFixture.user(true),
      admin_elevated: PasskeyFixture.elevate(PasskeyFixture.user(true))
    }

    grants = %{
      owner: [users.co_owner.id],
      writer: [users.writer.id],
      viewer: [users.viewer.id]
    }

    id = Ash.UUID.generate()

    for {kind, actor} <- users, action <- @actions, active? <- [true, false] do
      entity = Marshall.CedarEntities.artifact(id, owner.id, grants, active?)
      expected = active? and action in Map.fetch!(@table, kind)

      assert Cedar.allowed?(actor, action, entity) == expected,
             "#{kind} #{action} active=#{active?}: expected #{expected}"
    end
  end

  test "any authenticated user may create; the system actor may not" do
    assert Cedar.allowed?(
             PasskeyFixture.user(false),
             "artifact_create",
             Cedar.entity("ControlPlane", "marshall")
           )

    refute Cedar.allowed?(
             Marshall.Authorization.SystemActor.compute(),
             "artifact_read",
             Marshall.CedarEntities.artifact(Ash.UUID.generate(), Ash.UUID.generate(), %{}, true)
           )
  end
end
