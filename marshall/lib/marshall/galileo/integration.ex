# @cc [owner:ghuntley,label:security] galileo-secret-write-only
# Integration secret values MUST be Cloak-encrypted, excluded from default
# decryption and omitted in plaintext and ciphertext form from audit versions.
# No user-facing surface may return a stored value; display is redacted.
defmodule Marshall.Galileo.Integration do
  @moduledoc "Named edge integration owned by a user or a team; never carries authority itself."
  use Ash.Resource,
    otp_app: :marshall,
    domain: Marshall.Galileo,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Marshall.Authorization.AshAuthorizer],
    extensions: [AshArchival.Resource, AshPaperTrail.Resource]

  postgres do
    table "galileo_integrations"
    repo Marshall.Repo
    identity_wheres_to_sql active_name: "archived_at IS NULL"

    check_constraints do
      check_constraint :owner_id, "galileo_owner_xor_team",
        check: "(owner_id IS NOT NULL)::int + (team_id IS NOT NULL)::int = 1"

      check_constraint :peer, "galileo_peer_target_shape",
        check:
          "(peer = false AND target IS NOT NULL AND peer_vm_id IS NULL) OR (peer = true AND target IS NULL AND peer_vm_id IS NOT NULL)"
    end
  end

  cedar do
    control_plane "admin_read", [:list_for_admin]
    control_plane "provision", [:configure, :remove, :attach, :detach, :show, :list_for_user]
    internal [:read, :history, :register, :edit, :archive]
  end

  archive do
    exclude_read_actions([:history])
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

  actions do
    defaults [:read]
    read :history

    create :register do
      accept [
        :name,
        :target,
        :strip_prefix,
        :peer,
        :owner_id,
        :team_id,
        :peer_vm_id,
        :comment,
        :idempotency_key
      ]
    end

    update :edit do
      accept [
        :target,
        :strip_prefix,
        :peer,
        :peer_vm_id,
        :comment,
        :owner_id,
        :team_id,
        :idempotency_key
      ]
    end

    destroy :archive

    action :configure, :struct do
      constraints instance_of: Marshall.Galileo.Integration
      argument :name, :string, allow_nil?: false, constraints: [min_length: 1, max_length: 40]
      argument :target, :string, constraints: [min_length: 8, max_length: 2048]
      argument :strip_prefix, :string, constraints: [min_length: 2, max_length: 256]

      argument :headers, {:array, :map},
        allow_nil?: false,
        default: [],
        constraints: [
          max_items: 16,
          items: [
            fields: [
              kind: [type: :atom, constraints: [one_of: [:static, :bearer, :basic]]],
              name: [type: :string, constraints: [min_length: 1, max_length: 64]],
              value: [type: :string, constraints: [min_length: 1, max_length: 4096]]
            ]
          ]
        ]

      argument :peer, :boolean, allow_nil?: false, default: false
      argument :peer_vm_id, :uuid
      argument :team_id, :uuid

      argument :comment, :string,
        allow_nil?: false,
        default: "",
        constraints: [max_length: 2048, allow_empty?: true]

      argument :idempotency_key, :string,
        allow_nil?: false,
        constraints: [min_length: 1, max_length: 128]

      run Marshall.Galileo.Configurations
    end

    action :remove, :map do
      argument :name, :string, allow_nil?: false, constraints: [min_length: 1, max_length: 40]
      run {Marshall.Galileo.Configurations, operation: :remove}
    end

    action :attach, :map do
      argument :name, :string, allow_nil?: false, constraints: [min_length: 1, max_length: 40]
      argument :vm_id, :uuid, allow_nil?: false
      run {Marshall.Galileo.Configurations, operation: :attach}
    end

    action :detach, :map do
      argument :name, :string, allow_nil?: false, constraints: [min_length: 1, max_length: 40]
      argument :vm_id, :uuid, allow_nil?: false
      run {Marshall.Galileo.Configurations, operation: :detach}
    end

    action :show, :map do
      argument :name, :string, allow_nil?: false, constraints: [min_length: 1, max_length: 40]
      run {Marshall.Galileo.Configurations, operation: :show}
    end

    action :list_for_user, {:array, :map} do
      argument :after, :uuid
      argument :limit, :integer, allow_nil?: false, default: 50, constraints: [min: 1, max: 100]
      run {Marshall.Galileo.Configurations, operation: :list}
    end

    action :list_for_admin, {:array, :map} do
      argument :after, :uuid
      argument :limit, :integer, allow_nil?: false, default: 100, constraints: [min: 1, max: 100]
      run Marshall.Galileo.AdminActions
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :name, :string,
      allow_nil?: false,
      constraints: [
        min_length: 1,
        max_length: 40,
        match: ~r/\A[a-z][a-z0-9-]{0,38}[a-z0-9]\z|\A[a-z]\z/
      ]

    attribute :target, :string, constraints: [min_length: 8, max_length: 2048]
    attribute :strip_prefix, :string, constraints: [min_length: 2, max_length: 256]
    # @cc [owner:ghuntley,label:product] integration-empty-reflection-comment
    # An integration without an operator comment MUST retain the empty-string
    # default so ordinary registration remains valid.
    attribute :comment, :string,
      allow_nil?: false,
      default: "",
      constraints: [max_length: 2048, allow_empty?: true]

    attribute :peer, :boolean, allow_nil?: false, default: false

    attribute :idempotency_key, :string,
      allow_nil?: false,
      constraints: [min_length: 1, max_length: 128]

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  relationships do
    belongs_to :owner, Marshall.Accounts.User
    belongs_to :team, Marshall.Teams.Team
    belongs_to :peer_vm, Marshall.Compute.VirtualMachine, attribute_type: :uuid
    has_many :headers, Marshall.Galileo.IntegrationHeader, destination_attribute: :integration_id
    has_many :attachments, Marshall.Galileo.Attachment, destination_attribute: :integration_id
  end

  identities do
    identity :active_name, [:name], where: expr(is_nil(archived_at))
  end
end
