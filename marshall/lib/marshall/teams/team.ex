defmodule Marshall.Teams.Team do
  @moduledoc "A named team pooling machines and integrations under one ownership line."
  @name_constraints [
    min_length: 1,
    max_length: 63,
    match: ~r/\A[a-z][a-z0-9-]{0,61}[a-z0-9]\z|\A[a-z]\z/
  ]

  @typedoc "Who governs the team: native roles, SCIM, or a retirement/handoff state."
  @type management_mode :: :native | :scim_managed | :retiring | :handoff_pending

  use Ash.Resource,
    otp_app: :marshall,
    domain: Marshall.Teams,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Marshall.Authorization.AshAuthorizer],
    extensions: [AshArchival.Resource, AshPaperTrail.Resource, AshScim.Group]

  postgres do
    table "teams"
    repo Marshall.Repo
    identity_wheres_to_sql active_name: "archived_at IS NULL"
  end

  cedar do
    control_plane "provision", [
      :create_team,
      :list_for_user,
      :list_all_for_user,
      :set_member,
      :list_members,
      :list_transfers
    ]

    internal [:read, :history, :register, :archive, :mark_retiring]
    service :scim, [:read, :scim_read, :scim_create, :scim_update, :scim_destroy]
  end

  archive do
    exclude_read_actions([:history])
    # SCIM DELETE starts retirement; TeamRetirementWorker archives the row.
    exclude_destroy_actions([:scim_destroy])
  end

  paper_trail do
    metadata :actor_kind, :atom, allow_nil?: true
    metadata :actor_id, :uuid, allow_nil?: true
    sensitive_attributes :ignore
    change_tracking_mode :changes_only
    store_action_name? true
    ignore_attributes [:inserted_at, :updated_at]
    version_extensions authorizers: [Marshall.Authorization.AshAuthorizer]
    mixin Marshall.Authorization.VersionMapping
  end

  # @cc [owner:ghuntley,label:security;product] scim-group-hidden-owner
  # SCIM Groups expose and manage only non-owner memberships: the hidden service
  # owner membership is never listed, matched, replaced or removed through SCIM.
  # SCIM reads list only :scim_managed teams; native and retiring teams are not
  # SCIM resources and every SCIM write refuses them.
  scim do
    read_action :scim_read
    create_action :scim_create
    update_action :scim_update
    destroy_action :scim_destroy
    map :displayName, attribute: :name
    map :externalId, attribute: :scim_external_id

    multivalued :members do
      relationship :scim_members
      use_identities([:scim_match])
      map :value, attribute: :user_id
    end
  end

  actions do
    defaults [:read]
    read :history

    read :scim_read do
      filter expr(management_mode == :scim_managed)
    end

    create :register do
      accept [:name, :created_by_id]
    end

    create :scim_create do
      accept [:name, :scim_external_id]
      primary? true
      change Marshall.Teams.ScimCreate
    end

    update :scim_update do
      accept [:name, :scim_external_id]
      primary? true
      require_atomic? false
      validate Marshall.Teams.ScimManaged
    end

    destroy :archive

    # @cc [owner:ghuntley,label:security;recovery] scim-group-delete-retires
    # SCIM DELETE MUST NOT archive directly: it revokes team authority, marks the
    # team retiring with an immediate deadline and enqueues TeamRetirementWorker,
    # which retires team machines before archiving the team, in one transaction.
    destroy :scim_destroy do
      soft? true
      require_atomic? false
      validate Marshall.Teams.ScimManaged
      change Marshall.Teams.ScimRetire
    end

    update :mark_retiring do
      accept [:management_mode, :scim_retirement_deadline]
      require_atomic? false
    end

    # @cc [owner:ghuntley,label:product] team-name-input-storage-parity
    # Public creation input and persisted names MUST share the same 1..63 ASCII
    # lowercase label grammar. Invalid names MUST fail before coordinator writes.
    action :create_team, :struct do
      constraints instance_of: Marshall.Teams.Team
      argument :name, :string, allow_nil?: false, constraints: @name_constraints

      argument :idempotency_key, :string,
        allow_nil?: false,
        constraints: [min_length: 1, max_length: 128]

      run Marshall.Teams.Coordinator
    end

    action :list_for_user, {:array, :map} do
      argument :after, :uuid
      argument :limit, :integer, allow_nil?: false, default: 50, constraints: [min: 1, max: 100]
      run {Marshall.Teams.Coordinator, operation: :list}
    end

    # @cc [owner:ghuntley,label:security;product] teams-all-read-only-directory
    # Every signed-in account may list active teams with their names, management
    # mode and visible member counts. The listing MUST exclude archived teams and
    # the hidden service owner and MUST NOT disclose member identities.
    action :list_all_for_user, {:array, :map} do
      argument :after, :uuid
      argument :limit, :integer, allow_nil?: false, default: 50, constraints: [min: 1, max: 100]
      run {Marshall.Teams.Coordinator, operation: :list_all}
    end

    action :set_member, :map do
      argument :team_id, :uuid, allow_nil?: false
      argument :email, :ci_string, allow_nil?: false, constraints: [max_length: 320]
      argument :role, :atom, allow_nil?: false, constraints: [one_of: [:admin, :member, :removed]]

      argument :idempotency_key, :string,
        allow_nil?: false,
        constraints: [min_length: 1, max_length: 128]

      run {Marshall.Teams.Coordinator, operation: :set_member}
    end

    action :list_members, {:array, :map} do
      argument :team_id, :uuid, allow_nil?: false
      run {Marshall.Teams.Coordinator, operation: :list_members}
    end

    action :list_transfers, {:array, :map} do
      argument :team_id, :uuid, allow_nil?: false
      run {Marshall.Teams.Coordinator, operation: :list_transfers}
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :name, :string,
      allow_nil?: false,
      constraints: @name_constraints

    attribute :scim_external_id, :string, allow_nil?: true, public?: true

    attribute :management_mode, :atom,
      allow_nil?: false,
      default: :native,
      constraints: [one_of: [:native, :scim_managed, :retiring, :handoff_pending]],
      public?: true

    attribute :scim_retirement_deadline, :utc_datetime_usec, allow_nil?: true, public?: true

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  relationships do
    belongs_to :created_by, Marshall.Accounts.User, allow_nil?: false
    has_many :members, Marshall.Teams.TeamMember, destination_attribute: :team_id

    has_many :scim_members, Marshall.Teams.TeamMember do
      destination_attribute :team_id
      filter expr(role != :owner)
    end

    has_many :machines, Marshall.Compute.VirtualMachine, destination_attribute: :team_id
  end

  identities do
    identity :active_name, [:name], where: expr(is_nil(archived_at))
  end
end
