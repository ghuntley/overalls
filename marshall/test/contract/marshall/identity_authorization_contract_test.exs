defmodule MarshallIdentityAuthorizationContractTest do
  use Covenant.Case, component: "marshall.identity_authorization"

  @tag obligation: "marshall.identity_authorization.I1"
  test "declared modules compile and remain loadable" do
    modules = [
      Marshall.Access,
      Marshall.Access.AdminActions,
      Marshall.Access.Authorization,
      Marshall.Access.Change,
      Marshall.Access.Grant,
      Marshall.Access.Pin,
      Marshall.Access.Pins,
      Marshall.Access.Sharing,
      Marshall.Accounts,
      Marshall.Accounts.AccountLifecycle,
      Marshall.Accounts.AdminBootstrap,
      Marshall.Accounts.AdminEvent,
      Marshall.Accounts.AdminEvents,
      Marshall.Accounts.AdminUsers,
      Marshall.Accounts.Administrators,
      Marshall.Accounts.AuthEmail,
      Marshall.Accounts.AuthEmails,
      Marshall.Accounts.BootstrapAdministrator,
      Marshall.Accounts.DeleteUserMachines,
      Marshall.Accounts.DeliverAuthEmail,
      Marshall.Accounts.EligibleEmail,
      Marshall.Accounts.EmailAddress,
      Marshall.Accounts.GuestAccount,
      Marshall.Accounts.GuestAccounts,
      Marshall.Accounts.GuestUsername,
      Marshall.Accounts.Login,
      Marshall.Accounts.MagicLinkSignIn,
      Marshall.Accounts.Passkey,
      Marshall.Accounts.PasskeyChallenge,
      Marshall.Accounts.Profile,
      Marshall.Accounts.PruneSecurity,
      Marshall.Accounts.RegistrationFence,
      Marshall.Accounts.RememberedLogin,
      Marshall.Accounts.Security,
      Marshall.Accounts.TimeZones,
      Marshall.Accounts.Token,
      Marshall.Accounts.User,
      Marshall.Accounts.User.Senders.SendMagicLinkEmail,
      Marshall.Accounts.UserDeletion,
      Marshall.Accounts.ValidTimeZone,
      Marshall.Accounts.Verification,
      Marshall.Administration,
      Marshall.Administration.AuditEvent,
      Marshall.Administration.ExpireJobHistory,
      Marshall.Administration.JobEvent,
      Marshall.Administration.JobSnapshot,
      Marshall.Administration.Jobs,
      Marshall.Administration.Operations,
      Marshall.Authorization,
      Marshall.Authorization.AshAuthorizer,
      Marshall.Authorization.Cedar,
      Marshall.Authorization.DecisionSnapshot,
      Marshall.Authorization.Entity,
      Marshall.Authorization.Filter,
      Marshall.Authorization.Native,
      Marshall.Authorization.Principal,
      Marshall.Authorization.Record,
      Marshall.Authorization.Resource.Info,
      Marshall.Authorization.Resource.Persist,
      Marshall.Authorization.Resource.Rule,
      Marshall.Authorization.Resource.Verifier,
      Marshall.Authorization.SystemActor,
      Marshall.Authorization.VersionMapping,
      Marshall.Teams,
      Marshall.Teams.Coordinator,
      Marshall.Teams.Team,
      Marshall.Teams.TeamMember,
      Marshall.Teams.Transfer,
      Marshall.Teams.TransferSwap
    ]

    assert Enum.all?(modules, &Code.ensure_loaded?/1)
  end

  @tag obligation: "marshall.identity_authorization.I2"
  test "the compute actor is a typed, non-user principal" do
    actor = Marshall.Authorization.SystemActor.compute()
    assert %Marshall.Authorization.SystemActor{purpose: :compute} = actor
    refute Map.has_key?(actor, :id)

    assert Marshall.Authorization.Cedar.allowed?(
             actor,
             "read",
             Marshall.Authorization.Cedar.entity("VM", "vm-1")
           ) == false
  end

  @tag obligation: "marshall.identity_authorization.I3"
  test "account boundary validators reject unsafe identity input" do
    assert Marshall.Accounts.EmailAddress.valid?("alice@example.com")
    refute Marshall.Accounts.EmailAddress.valid?("Alice Example <alice@example.com>")
    refute Marshall.Accounts.EmailAddress.valid?("alice\r\n@example.com")
    refute Marshall.Accounts.EmailAddress.valid?(String.duplicate("a", 255) <> "@x.test")
    refute Marshall.Accounts.EmailAddress.valid?(nil)
    refute Marshall.Accounts.EmailAddress.valid?("alice @example.com")

    assert Marshall.Accounts.GuestUsername.from_uid(200_000) == {:ok, "u200000"}
    assert Marshall.Accounts.GuestUsername.from_uid(999_999) == {:ok, "u999999"}
    assert Marshall.Accounts.GuestUsername.from_uid(199_999) == :error
    assert Marshall.Accounts.GuestUsername.from_uid(1_000_000) == :error
    assert Marshall.Accounts.GuestUsername.from_uid("200000") == :error
  end

  @tag obligation: "marshall.identity_authorization.I4"
  test "security proof freshness is bounded in both directions" do
    verified = ~U[2026-01-01 00:00:00Z]
    now = ~U[2026-01-01 00:05:00Z]
    expiry = ~U[2026-01-01 00:10:00Z]

    assert Marshall.Accounts.Security.elevation_fresh?(verified, expiry, now)
    refute Marshall.Accounts.Security.elevation_fresh?(~U[2026-01-01 00:11:00Z], expiry, now)
    refute Marshall.Accounts.Security.elevation_fresh?(verified, ~U[2026-01-01 00:04:59Z], now)
    refute Marshall.Accounts.Security.elevation_fresh?(nil, expiry, now)

    assert Marshall.Accounts.Security.email_fresh?(~U[2026-01-01 00:04:00Z], now)
    refute Marshall.Accounts.Security.email_fresh?(~U[2025-12-31 23:00:00Z], now)
    refute Marshall.Accounts.Security.email_fresh?(nil, now)
  end

  @tag obligation: "marshall.identity_authorization.I5"
  test "the pin state machine has exactly two transitions from a pinned start" do
    assert AshStateMachine.Info.state_machine_initial_states!(Marshall.Access.Pin) == [:pinned]

    assert AshStateMachine.Info.state_machine_default_initial_state!(Marshall.Access.Pin) ==
             :pinned

    assert Enum.sort(AshStateMachine.Info.state_machine_all_states(Marshall.Access.Pin)) == [
             :pinned,
             :unpinned
           ]

    transitions =
      Marshall.Access.Pin
      |> AshStateMachine.Info.state_machine_transitions()
      |> Enum.map(&{&1.action, List.wrap(&1.from), List.wrap(&1.to)})
      |> Enum.sort()

    assert transitions == [{:repin, [:unpinned], [:pinned]}, {:unpin, [:pinned], [:unpinned]}]
    assert Marshall.Access.Pins.limit() == 20
  end

  @tag obligation: "marshall.identity_authorization.I6"
  test "pin projections are empty for every non-user actor" do
    vm = %Marshall.Compute.VirtualMachine{id: Ash.UUID.generate(), owner_id: Ash.UUID.generate()}

    for actor <- [Marshall.Authorization.SystemActor.compute(), nil, %{id: Ash.UUID.generate()}] do
      assert Marshall.Access.Pins.pinned_vm_ids(actor) == []
      refute Marshall.Access.Pins.pinned?(vm, actor)
    end
  end

  @tag obligation: "marshall.identity_authorization.I7"
  test "time zone validation accepts only resolvable identifiers and never raises" do
    alias Marshall.Accounts.TimeZones
    instant = ~U[2026-10-18 09:12:07Z]

    for zone <- ["Australia/Adelaide", "Etc/UTC", "America/Argentina/Ushuaia"] do
      assert TimeZones.valid?(zone)
      assert TimeZones.shift(instant, zone).time_zone == zone
    end

    for bad <- [
          nil,
          "",
          :"Etc/UTC",
          42,
          "australia/adelaide",
          "Mars/Olympus",
          "Etc/UTC\n",
          String.duplicate("a", 65)
        ] do
      refute TimeZones.valid?(bad)
    end

    assert TimeZones.shift(instant, "Mars/Olympus").time_zone == "Etc/UTC"
    assert TimeZones.shift(instant, nil).time_zone == "Etc/UTC"

    changeset =
      Ash.Changeset.for_update(
        struct(Marshall.Accounts.User, %{id: Ash.UUID.generate()}),
        :store_time_zone,
        %{time_zone: "Mars/Olympus"},
        actor: Marshall.Authorization.SystemActor.compute()
      )

    refute changeset.valid?
  end

  @tag obligation: "marshall.identity_authorization.I8"
  test "picker labels carry the current offset and differences are antisymmetric" do
    alias Marshall.Accounts.TimeZones
    summer = ~U[2026-12-01 00:00:00Z]
    options = TimeZones.options(summer)

    assert options == Enum.sort_by(options, &{&1.offset, &1.city})
    assert Enum.map(options, & &1.zone) |> Enum.uniq() |> length() == length(options)
    assert Enum.find(options, &(&1.zone == "Australia/Adelaide")).label == "(GMT+10:30) Adelaide"
    assert Enum.find(options, &(&1.zone == "Asia/Kathmandu")).label == "(GMT+05:45) Kathmandu"

    for {a, b} <- [{"Europe/London", "Australia/Adelaide"}, {"Asia/Tokyo", "America/New_York"}] do
      ab = TimeZones.difference(a, b, summer)
      ba = TimeZones.difference(b, a, summer)
      assert ab.minutes == -ba.minutes
      assert (ab.minutes > 0 and ab.text =~ "ahead of you") or ab.text =~ "behind you"
      assert TimeZones.difference(a, a, summer) == %{minutes: 0, text: "same time as you"}
    end
  end
end
