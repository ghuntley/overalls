defmodule Marshall.Terminal.Opening do
  @moduledoc "Immutable bounded terminal-create intent and its idempotency receipt."
  use Ash.Resource,
    otp_app: :marshall,
    domain: Marshall.Terminal,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Marshall.Authorization.AshAuthorizer],
    extensions: [AshStateMachine, AshOban]

  postgres do
    table "terminal_openings"
    repo Marshall.Repo

    check_constraints do
      check_constraint :parameter_hash, "terminal_opening_receipt",
        check:
          "execution_epoch > 0 AND octet_length(parameter_hash) = 32 AND ((status = 'ready' AND session_id IS NOT NULL) OR (status IN ('pending', 'cancelling', 'failed') AND session_id IS NULL))"
    end

    custom_indexes do
      index [:vm_id, :status]
      index [:inserted_at]
    end
  end

  cedar do
    internal [:destroy, :read, :reserve, :complete, :fail, :begin_cancel, :reconcile]
  end

  # @cc [owner:ghuntley,label:recovery;security] terminal-create-intent-is-metadata
  # A request ID MUST bind one actor, VM, placement/epoch and parameter digest.
  # Pending intent MUST precede guest creation, and completion MUST transact with
  # the registry and opened receipt. Guest user, TERM, tokens and terminal bytes
  # MUST NOT be stored; retries supply the original parameters and match the digest.
  state_machine do
    state_attribute :status
    initial_states [:pending]
    default_initial_state :pending

    transitions do
      transition :complete, from: :pending, to: :ready
      transition :begin_cancel, from: :pending, to: :cancelling
      transition :fail, from: [:pending, :cancelling], to: :failed
    end
  end

  oban do
    scheduled_actions do
      schedule :reconcile, "* * * * *" do
        action :reconcile
        queue :maintenance
        max_attempts 5
        worker_module_name Marshall.Terminal.Workers.Reconcile
        actor_persister :none
        default_actor %Marshall.Authorization.SystemActor{purpose: :compute}
      end
    end
  end

  actions do
    defaults [:read, :destroy]

    create :reserve do
      primary? true

      accept [
        :id,
        :vm_id,
        :actor_id,
        :placement_id,
        :execution_epoch,
        :parameter_hash,
        :expires_at
      ]
    end

    update :complete do
      accept [:session_id]
      change transition_state(:ready)
    end

    update :fail do
      accept []
      change transition_state(:failed)
    end

    update :begin_cancel do
      accept []
      change transition_state(:cancelling)
    end

    action :reconcile, :integer do
      transaction? false
      argument :after_vm, :uuid
      argument :vm_id, :uuid
      argument :after_opening, :uuid
      argument :after_session, :uuid
      run Marshall.Terminal.Reconciler
    end
  end

  attributes do
    attribute :id, :uuid, primary_key?: true, allow_nil?: false
    attribute :vm_id, :uuid, allow_nil?: false
    attribute :actor_id, :uuid, allow_nil?: false
    attribute :placement_id, :uuid, allow_nil?: false
    attribute :execution_epoch, :integer, allow_nil?: false, constraints: [min: 1]
    attribute :parameter_hash, :binary, allow_nil?: false
    attribute :session_id, :uuid
    attribute :expires_at, :utc_datetime_usec, allow_nil?: false
    create_timestamp :inserted_at
  end
end
