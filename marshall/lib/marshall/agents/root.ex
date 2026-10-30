defmodule Marshall.Agents.Root do
  @moduledoc "One automatically registered agent identity for each eligible VM."
  use Ash.Resource,
    otp_app: :marshall,
    domain: Marshall.Agents,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Marshall.Authorization.AshAuthorizer],
    extensions: [AshPaperTrail.Resource]

  postgres do
    table "agent_roots"
    repo Marshall.Repo

    custom_indexes do
      index [:vm_id], unique: true
    end
  end

  cedar do
    internal [:read, :register]
  end

  paper_trail do
    metadata :actor_kind, :atom, allow_nil?: true
    metadata :actor_id, :uuid, allow_nil?: true
    sensitive_attributes :ignore
    change_tracking_mode :changes_only
    store_action_name? true
    ignore_attributes [:inserted_at]
    version_extensions authorizers: [Marshall.Authorization.AshAuthorizer]
    mixin Marshall.Authorization.VersionMapping
  end

  actions do
    defaults [:read]

    create :register do
      accept [:vm_id, :owner_id]
    end
  end

  attributes do
    uuid_v7_primary_key :id
    attribute :vm_id, :uuid, allow_nil?: false
    attribute :owner_id, :uuid, allow_nil?: false
    create_timestamp :inserted_at
  end
end
