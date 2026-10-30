defmodule Marshall.SSH.HostCertificate do
  @moduledoc "Public SSH host certificate generations, serialized by authenticated subject."
  use Ash.Resource,
    otp_app: :marshall,
    domain: Marshall.SSH,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Marshall.Authorization.AshAuthorizer],
    extensions: [AshStateMachine, AshOban]

  postgres do
    table "ssh_host_certificates"
    repo Marshall.Repo

    custom_indexes do
      index [:subject],
        unique: true,
        where: "status != 'superseded'",
        name: "ssh_host_certificates_current_subject"

      index [:updated_at, :id], where: "status = 'superseded'"
      index [:valid_before, :id]
    end
  end

  cedar do
    internal [:read, :purge, :prune, :record, :issue, :retry, :fail, :supersede, :request]
  end

  state_machine do
    state_attribute :status
    initial_states [:pending]
    default_initial_state :pending

    transitions do
      transition :issue, from: :pending, to: :issued
      transition :fail, from: :pending, to: :failed
      transition :retry, from: :failed, to: :pending
      transition :supersede, from: [:pending, :issued, :failed], to: :superseded
    end
  end

  oban do
    scheduled_actions do
      schedule :prune, "17 * * * *" do
        action :prune
        queue :maintenance
        max_attempts 5
        worker_module_name Marshall.SSH.Workers.PruneHostCertificates
        actor_persister :none
        default_actor %Marshall.Authorization.SystemActor{purpose: :compute}
      end
    end
  end

  actions do
    defaults [:read]

    destroy :purge

    action :prune, :integer do
      argument :continuation, :uuid
      run Marshall.SSH.HostCertificateRetention
    end

    create :record do
      accept [:subject, :public_key, :principal, :ca, :serial, :valid_after, :valid_before]
    end

    update :issue do
      accept [:certificate]
      change transition_state(:issued)
    end

    update :retry do
      accept []
      change transition_state(:pending)
    end

    update :fail do
      accept []
      change transition_state(:failed)
    end

    update :supersede do
      accept []
      change transition_state(:superseded)
    end

    action :request, :map do
      argument :role, :atom, allow_nil?: false, constraints: [one_of: [:porsche, :audi, :guest]]
      argument :token, :string, allow_nil?: false, sensitive?: true, constraints: [max_length: 80]
      argument :public_key, :string, allow_nil?: false, constraints: [max_length: 4096]
      argument :binding, :map
      run Marshall.SSH.HostCertificates
    end
  end

  attributes do
    uuid_primary_key :id
    attribute :subject, :string, allow_nil?: false
    attribute :public_key, :string, allow_nil?: false
    attribute :principal, :string, allow_nil?: false
    attribute :ca, :string, allow_nil?: false
    attribute :serial, :integer, allow_nil?: false
    attribute :valid_after, :integer, allow_nil?: false
    attribute :valid_before, :integer, allow_nil?: false
    attribute :certificate, :string

    attribute :status, :atom,
      allow_nil?: false,
      default: :pending,
      constraints: [one_of: [:pending, :issued, :failed, :superseded]]

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end
end
