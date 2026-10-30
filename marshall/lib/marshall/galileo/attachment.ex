# @cc [owner:ghuntley,label:security] galileo-attachment-current-pair
# Each integration/VM pair MUST have at most one unarchived attachment and
# attachment alone MUST NOT authorize requests for unowned machines.
defmodule Marshall.Galileo.Attachment do
  @moduledoc "Explicit integration-to-machine availability; replacement retains history."
  use Ash.Resource,
    otp_app: :marshall,
    domain: Marshall.Galileo,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Marshall.Authorization.AshAuthorizer],
    extensions: [AshArchival.Resource, AshPaperTrail.Resource]

  postgres do
    table "galileo_attachments"
    repo Marshall.Repo
    identity_wheres_to_sql current_pair: "archived_at IS NULL"
  end

  cedar do
    internal [:read, :history, :attach, :detach]
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

    create :attach do
      accept [:integration_id, :vm_id, :attached_by_id]
    end

    destroy :detach
  end

  attributes do
    uuid_primary_key :id
    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  relationships do
    belongs_to :integration, Marshall.Galileo.Integration, allow_nil?: false
    belongs_to :vm, Marshall.Compute.VirtualMachine, allow_nil?: false
    belongs_to :attached_by, Marshall.Accounts.User, allow_nil?: false
  end

  identities do
    identity :current_pair, [:integration_id, :vm_id], where: expr(is_nil(archived_at))
  end
end
