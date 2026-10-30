defmodule Marshall.Accounts.AdminEvent do
  @moduledoc "Append-only administrator authority audit; no credentials or request payloads."
  use Ash.Resource,
    otp_app: :marshall,
    domain: Marshall.Accounts,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Marshall.Authorization.AshAuthorizer]

  postgres do
    table "account_admin_events"
    repo Marshall.Repo
  end

  cedar do
    control_plane "admin_read", [:list_for_admin]
    internal [:read, :record]
  end

  actions do
    defaults [:read]

    action :list_for_admin, :map do
      argument :before, :uuid
      argument :limit, :integer, allow_nil?: false, default: 100, constraints: [min: 1, max: 100]
      run Marshall.Accounts.AdminEvents
    end

    create :record do
      accept [:actor_id, :target_id, :kind]
    end
  end

  attributes do
    uuid_primary_key :id
    attribute :actor_id, :uuid, allow_nil?: false
    attribute :target_id, :uuid, allow_nil?: false

    attribute :kind, :atom,
      allow_nil?: false,
      constraints: [
        one_of: [
          :passkey_add,
          :passkey_remove,
          :mfa_verify,
          :mfa_reset,
          :user_invite,
          :user_delete,
          :bootstrap,
          :grant,
          :revoke,
          :sessions_revoke,
          :vm_grant_revoke,
          :ssh_key_revoke,
          :ssh_session_revoke,
          :evacuation_request,
          :evacuation_control,
          :evacuation_approve,
          :evacuation_replan,
          :host_configure,
          :fleet_certificate_rotate,
          :vm_lifecycle,
          :vm_relocate,
          :team_create,
          :team_membership_change,
          :team_transfer_offer,
          :team_transfer_accept,
          :team_transfer_decline,
          :team_transfer_cancel,
          :galileo_configure,
          :galileo_remove,
          :galileo_attach,
          :galileo_detach
        ]
      ]

    create_timestamp :inserted_at
  end
end
