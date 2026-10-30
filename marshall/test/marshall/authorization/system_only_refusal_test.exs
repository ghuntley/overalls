defmodule Marshall.Authorization.SystemOnlyRefusalTest do
  use Marshall.DataCase, async: false

  alias Marshall.Accounts
  alias Marshall.Authorization.{AshAuthorizer, SystemActor}

  @internal [
    Accounts.UserDeletion,
    Accounts.ScimMachineSuspension,
    Accounts.PasskeyChallenge,
    Accounts.Passkey,
    Accounts.Verification,
    Accounts.GuestAccount,
    Marshall.SSH.GuestLogin,
    Marshall.Threads.ScimArchiveProjection
  ]

  setup do
    user = Marshall.PasskeyFixture.user()
    admin = Marshall.PasskeyFixture.elevate(Marshall.PasskeyFixture.user(true))
    %{user: user, admin: admin}
  end

  # @cc [owner:ghuntley,label:security] system-only-resource-refusal
  # Resources whose every action is internal MUST refuse ordinary users,
  # elevated administrators, a nil actor and both library service principals,
  # and MUST admit the compute system principal. Token actions MUST admit only
  # AshAuthentication's service principal.
  test "system-only resources refuse every principal but the compute system", c do
    refused = [
      nil,
      c.user,
      c.admin,
      SystemActor.service(:ash_authentication),
      SystemActor.service(:scim)
    ]

    for resource <- @internal, action <- entry_actions(resource) do
      for actor <- refused,
          do: refute(Ash.can?({resource, action}, actor), label(resource, action, actor))

      assert Ash.can?({resource, action}, SystemActor.compute()),
             label(resource, action, SystemActor.compute())
    end
  end

  test "token actions admit only AshAuthentication's service principal", c do
    refused = [nil, c.user, c.admin, SystemActor.compute(), SystemActor.service(:scim)]

    for action <- entry_actions(Accounts.Token) do
      for actor <- refused,
          do: refute(entry?(Accounts.Token, action, actor), label(Accounts.Token, action, actor))

      assert entry?(Accounts.Token, action, SystemActor.service(:ash_authentication)),
             label(Accounts.Token, action, SystemActor.service(:ash_authentication))
    end
  end

  # Token reads prepare from AshAuthentication's strategy context, which
  # `Ash.can?` cannot supply, so the entry decision is asked of the authorizer.
  defp entry?(resource, action, actor) do
    state = AshAuthorizer.initial_state(actor, resource, %{name: action}, Accounts)
    match?({:authorized, _}, AshAuthorizer.strict_check(state, %{}))
  end

  # Actions decided without a loaded record: reads, creates and generic actions.
  defp entry_actions(resource) do
    actions =
      for %{type: type, name: name} <- Ash.Resource.Info.actions(resource),
          type in [:read, :create, :action],
          do: name

    assert actions != [], inspect(resource)
    actions
  end

  defp label(resource, action, actor),
    do: "#{inspect(resource)}.#{action} as #{principal(actor)}"

  defp principal(%SystemActor{purpose: purpose}), do: inspect(purpose)
  defp principal(%Accounts.User{administrator: true}), do: "administrator"
  defp principal(%Accounts.User{}), do: "user"
  defp principal(other), do: inspect(other)
end
