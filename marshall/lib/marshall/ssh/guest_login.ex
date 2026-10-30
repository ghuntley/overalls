defmodule Marshall.SSH.GuestLogin do
  @moduledoc "Durable guest-reported sshd PAM login, subordinate to the trusted Audi session."
  use Ash.Resource,
    otp_app: :marshall,
    domain: Marshall.SSH,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Marshall.Authorization.AshAuthorizer]

  postgres do
    table "ssh_guest_logins"
    repo Marshall.Repo
  end

  cedar do
    internal [:read, :record]
  end

  actions do
    defaults [:read]

    create :record do
      accept [:vm_id, :user_id, :key_id, :host_id, :placement_id, :execution_epoch]
    end
  end

  attributes do
    uuid_primary_key :id
    attribute :vm_id, :uuid, allow_nil?: false
    attribute :user_id, :uuid, allow_nil?: false
    attribute :key_id, :uuid, allow_nil?: false
    attribute :host_id, :uuid, allow_nil?: false
    attribute :placement_id, :uuid, allow_nil?: false
    attribute :execution_epoch, :integer, allow_nil?: false
    create_timestamp :inserted_at
  end
end
