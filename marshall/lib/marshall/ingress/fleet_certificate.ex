defmodule Marshall.Ingress.FleetCertificate do
  @moduledoc "One durable fleet wildcard order and its monotonic installation generation."
  use Ash.Resource,
    otp_app: :marshall,
    domain: Marshall.Ingress,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Marshall.Authorization.AshAuthorizer],
    extensions: [AshCloak, AshOban, AshStateMachine, AshPaperTrail.Resource]

  postgres do
    table "ingress_fleet_certificates"
    repo Marshall.Repo

    custom_indexes do
      index [:zone, :generation], unique: true
      index [:status, :inserted_at]
      index [:zone], unique: true, where: "status = 'active'"
    end
  end

  cedar do
    control_plane "admin_operate", [:rotate_for_admin]
    control_plane "admin_read", [:audit]

    internal [
      :read,
      :deliver,
      :acknowledge,
      :enqueue,
      :save_request,
      :mark_order_attempt,
      :bind_order,
      :record_proof,
      :refresh_proof,
      :finish_issued,
      :activate,
      :retire,
      :fail,
      :fail_unknown_order,
      :progress,
      :ensure_due
    ]
  end

  cloak do
    vault(Marshall.Vault)
    attributes([:csr_der, :private_key_pem, :chain_pem])
    decrypt_by_default([])
    encrypt_nil?(false)
  end

  oban do
    scheduled_actions do
      schedule :ensure_due, "* * * * *" do
        action :ensure_due
        queue :certificates
        worker_module_name Marshall.Ingress.Workers.EnsureFleetCertificate
        actor_persister :none
        default_actor %Marshall.Authorization.SystemActor{purpose: :compute}
      end
    end

    triggers do
      trigger :progress do
        action :progress
        queue :certificates
        scheduler_cron "* * * * *"
        where expr(status in [:pending, :challenging, :issued])
        worker_module_name Marshall.Ingress.Workers.ProgressFleetCertificate
        scheduler_module_name Marshall.Ingress.Workers.ScheduleFleetCertificate
        actor_persister :none
        default_actor %Marshall.Authorization.SystemActor{purpose: :compute}
        log_errors? false
        log_final_error? false
      end
    end
  end

  # @cc [owner:ghuntley,label:security;recovery] fleet-certificate-transitions
  # A generation MUST move only through named actions. Oban execution, a saved
  # order, or a DNS proof MUST NOT itself make it active. Older generations
  # cannot become active after a newer one, even if a delayed job finishes.
  state_machine do
    state_attribute :status
    initial_states [:pending]
    default_initial_state :pending

    transitions do
      transition :bind_order, from: :pending, to: :challenging
      transition :finish_issued, from: :challenging, to: :issued
      transition :activate, from: :issued, to: :active
      transition :retire, from: :active, to: :retired
      transition :fail, from: [:pending, :challenging], to: :failed
      transition :fail_unknown_order, from: :pending, to: :failed
    end
  end

  paper_trail do
    metadata :actor_kind, :atom, allow_nil?: true
    metadata :actor_id, :uuid, allow_nil?: true
    sensitive_attributes :ignore
    change_tracking_mode :changes_only
    store_action_name? true

    ignore_attributes [
      :inserted_at,
      :updated_at,
      :order_url,
      :finalize_url,
      :authorization_url,
      :dns_proof,
      :proof_expires_at,
      :csr_der,
      :private_key_pem,
      :chain_pem,
      :encrypted_csr_der,
      :encrypted_private_key_pem,
      :encrypted_chain_pem
    ]

    ignore_actions [:refresh_proof]
    version_extensions authorizers: [Marshall.Authorization.AshAuthorizer]
    mixin Marshall.Authorization.VersionMapping
  end

  actions do
    defaults [:read]

    action :audit, :map do
      run Marshall.Ingress.FleetCertificateAudit
    end

    action :rotate_for_admin, :map do
      run Marshall.Ingress.RotateFleetCertificate
    end

    action :deliver, :map do
      argument :service_token, :string,
        allow_nil?: false,
        sensitive?: true,
        constraints: [max_length: 80]

      run {Marshall.Ingress.FleetCertificateDelivery, operation: :deliver}
    end

    action :acknowledge, :map do
      argument :service_token, :string,
        allow_nil?: false,
        sensitive?: true,
        constraints: [max_length: 80]

      argument :generation, :integer, allow_nil?: false, constraints: [min: 1]
      argument :fingerprint, :string, allow_nil?: false, constraints: [max_length: 64]
      run {Marshall.Ingress.FleetCertificateDelivery, operation: :acknowledge}
    end

    create :enqueue do
      accept [:id, :generation, :zone]
      change run_oban_trigger(:progress)
    end

    update :save_request do
      accept [:csr_der, :private_key_pem, :csr_fingerprint]
    end

    update :mark_order_attempt do
      accept [:order_attempted_at]
    end

    update :bind_order do
      accept [:order_url, :finalize_url, :authorization_url]
      change transition_state(:challenging)
    end

    update :record_proof do
      accept [:dns_proof, :proof_expires_at]
    end

    update :refresh_proof do
      accept [:proof_expires_at]
    end

    update :finish_issued do
      accept [:chain_pem, :fingerprint, :expires_at]
      change transition_state(:issued)
    end

    update :activate do
      accept []
      change transition_state(:active)
    end

    update :retire do
      accept []
      change transition_state(:retired)
    end

    update :fail do
      accept []
      change transition_state(:failed)
    end

    update :fail_unknown_order do
      accept []
      change transition_state(:failed)
    end

    update :progress do
      accept []
      require_atomic? false
      transaction? false
      change Marshall.Ingress.FleetCertificateProgress
    end

    action :ensure_due, :integer do
      run Marshall.Ingress.EnsureFleetCertificate
    end
  end

  changes do
    # A new ACME proof enters the published zone; Audi DNS reads it at once.
    change {Marshall.Control.Hints.Change, kind: :dns_snapshot, from: :id},
      on: [:create, :update, :destroy],
      where: [action_is([:record_proof])]

    # An activated generation is fetched by every gateway at once (ADR-0142).
    change {Marshall.Control.Hints.Change, kind: :fleet_certificate, from: :id},
      on: [:create, :update, :destroy],
      where: [action_is([:activate])]
  end

  attributes do
    uuid_primary_key :id, writable?: true
    attribute :generation, :integer, allow_nil?: false, constraints: [min: 1]
    attribute :zone, :string, allow_nil?: false, constraints: [min_length: 1, max_length: 251]

    attribute :status, :atom,
      allow_nil?: false,
      default: :pending,
      constraints: [one_of: [:pending, :challenging, :issued, :active, :retired, :failed]]

    attribute :csr_fingerprint, :string, constraints: [max_length: 64]
    attribute :csr_der, :binary, sensitive?: true
    attribute :private_key_pem, :binary, sensitive?: true
    attribute :chain_pem, :binary, sensitive?: true
    attribute :order_attempted_at, :utc_datetime_usec
    attribute :order_url, :string, sensitive?: true, constraints: [max_length: 2048]
    attribute :finalize_url, :string, sensitive?: true, constraints: [max_length: 2048]
    attribute :authorization_url, :string, sensitive?: true, constraints: [max_length: 2048]
    attribute :dns_proof, :string, sensitive?: true, constraints: [max_length: 43]
    attribute :proof_expires_at, :utc_datetime_usec
    attribute :fingerprint, :string, constraints: [max_length: 64]
    attribute :expires_at, :utc_datetime_usec
    create_timestamp :inserted_at
    update_timestamp :updated_at
  end
end
