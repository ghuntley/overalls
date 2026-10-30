defmodule Marshall.Inference.Request do
  @moduledoc "Immutable admission identity and idempotent content-free completion."
  use Ash.Resource,
    otp_app: :marshall,
    domain: Marshall.Inference,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Marshall.Authorization.AshAuthorizer],
    extensions: [AshPaperTrail.Resource, AshOban]

  postgres do
    table "inference_requests"
    repo Marshall.Repo

    custom_indexes do
      index [:owner_id, :inserted_at, :id]
      index [:host_id, :expires_at]
      index [:inserted_at, :id]
    end

    check_constraints do
      check_constraint :execution_epoch, "inference_positive_epoch", check: "execution_epoch > 0"
      check_constraint :generation, "inference_positive_generation", check: "generation > 0"

      # Created with the legacy purge in 20261011210000; the closed key set
      # matches OverallsProtocol.Inference.completion/1 (ADR-0159).
      check_constraint :completion, "inference_completion_exact_shape",
        check:
          "completion IS NULL OR (jsonb_typeof(completion) = 'object' AND " <>
            "(completion - ARRAY['outcome', 'tokens', 'completeness', 'cost_estimate']) = '{}'::jsonb AND " <>
            "completion ?& ARRAY['outcome', 'tokens', 'completeness'])"
    end
  end

  cedar do
    control_plane "admin_read", [:list_for_admin]
    control_plane "provision", [:list_for_user]
    internal [:read, :prune, :record, :renew, :complete, :purge]
  end

  paper_trail do
    metadata :actor_kind, :atom, allow_nil?: true
    metadata :actor_id, :uuid, allow_nil?: true
    reference_source? false
    change_tracking_mode :changes_only
    store_action_name? true
    ignore_actions [:renew, :purge]
    ignore_attributes [:inserted_at, :updated_at]
    sensitive_attributes :ignore
    version_extensions authorizers: [Marshall.Authorization.AshAuthorizer]
    mixin Marshall.Authorization.VersionMapping
  end

  oban do
    scheduled_actions do
      schedule :prune, "17 * * * *" do
        action :prune
        queue :maintenance
        max_attempts 5
        worker_module_name Marshall.Inference.Workers.Prune
        actor_persister :none
        default_actor %Marshall.Authorization.SystemActor{purpose: :compute}
      end
    end
  end

  actions do
    defaults [:read]

    action :prune, :integer do
      argument :continuation, :uuid
      run Marshall.Inference.Retention
    end

    for name <- [:list_for_user, :list_for_admin] do
      action name, :map do
        argument :filters, :map, default: %{}
        run {Marshall.Inference.Views, admin: name == :list_for_admin}
      end
    end

    create :record do
      accept [
        :id,
        :host_id,
        :vm_id,
        :placement_id,
        :execution_epoch,
        :generation,
        :owner_id,
        :credential_id,
        :provider,
        :model,
        :operation,
        :expires_at
      ]
    end

    update :renew do
      accept [:expires_at]
    end

    update :complete do
      accept [:completion, :completed_at]
    end

    destroy :purge
  end

  attributes do
    uuid_primary_key :id, writable?: true
    attribute :execution_epoch, :integer, allow_nil?: false, constraints: [min: 1]
    attribute :generation, :integer, allow_nil?: false, constraints: [min: 1]
    attribute :provider, :atom, allow_nil?: false, constraints: [one_of: [:openai, :anthropic]]

    attribute :operation, :atom,
      allow_nil?: false,
      constraints: [one_of: [:responses, :chat, :messages, :count_tokens]]

    attribute :model, :string, allow_nil?: false, constraints: [max_length: 256]
    attribute :expires_at, :utc_datetime_usec, allow_nil?: false
    attribute :completion, :map
    attribute :completed_at, :utc_datetime_usec
    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  relationships do
    belongs_to :host, Marshall.Compute.Host, allow_nil?: false
    belongs_to :vm, Marshall.Compute.VirtualMachine, allow_nil?: false
    belongs_to :placement, Marshall.Compute.WorkloadPlacement, allow_nil?: false
    belongs_to :owner, Marshall.Accounts.User, allow_nil?: false
    belongs_to :credential, Marshall.Inference.Credential, allow_nil?: false
  end
end
