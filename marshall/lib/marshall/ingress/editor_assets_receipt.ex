defmodule Marshall.Ingress.EditorAssetsReceipt do
  @moduledoc "Authenticated immutable asset readiness pinned to gateway generation and host session."
  use Ash.Resource,
    otp_app: :marshall,
    domain: Marshall.Ingress,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Marshall.Authorization.AshAuthorizer],
    extensions: [AshPaperTrail.Resource]

  postgres do
    table "ingress_editor_assets_receipts"
    repo Marshall.Repo

    check_constraints do
      check_constraint :editor_protocol, "ingress_editor_assets_protocol",
        check: "editor_protocol = 1"

      check_constraint :service_generation, "ingress_editor_assets_generation",
        check: "service_generation > 0"

      check_constraint :editor_commit, "ingress_editor_assets_release",
        check: "editor_commit ~ '^[a-f0-9]{40}$' AND editor_release ~ '^[a-f0-9]{64}$'"
    end
  end

  # @cc [owner:ghuntley,label:security;protocol] editor-assets-attested-readiness
  # Only a freshly authenticated gateway may record assets readiness after local
  # descriptor/listener verification. The receipt MUST bind its current service
  # generation, host session and complete approved descriptor, so distinct
  # configured targets can attest independently without replacing one another.
  # Five-second readiness MUST expire without fresh authenticated announcements;
  # refresh MUST retain every binding and alter only the expiry.
  # Readiness MUST NOT authorize guest traffic or imply a browser probe passed.
  cedar do
    internal [:read, :report, :record, :refresh, :purge]
  end

  paper_trail do
    metadata :actor_kind, :atom, allow_nil?: true
    metadata :actor_id, :uuid, allow_nil?: true
    reference_source? false
    sensitive_attributes :ignore
    change_tracking_mode :changes_only
    store_action_name? true
    ignore_actions [:refresh, :purge]
    version_extensions authorizers: [Marshall.Authorization.AshAuthorizer]
    mixin Marshall.Authorization.VersionMapping
  end

  actions do
    defaults [:read]

    action :report, :map do
      argument :service_token, :string,
        allow_nil?: false,
        sensitive?: true,
        constraints: [max_length: 80]

      argument :editor_protocol, :integer, allow_nil?: false, constraints: [min: 1, max: 1]

      argument :editor_commit, :string,
        allow_nil?: false,
        constraints: [max_length: 40, trim?: false]

      argument :editor_release, :string,
        allow_nil?: false,
        constraints: [max_length: 64, trim?: false]

      run Marshall.Ingress.EditorAssets
    end

    create :record do
      accept [
        :service_id,
        :host_id,
        :service_generation,
        :session_id,
        :editor_protocol,
        :editor_commit,
        :editor_release,
        :expires_at
      ]
    end

    update :refresh do
      accept [:expires_at]
    end

    destroy :purge
  end

  attributes do
    uuid_primary_key :id
    attribute :service_generation, :integer, allow_nil?: false, constraints: [min: 1]
    attribute :session_id, :uuid, allow_nil?: false
    attribute :editor_protocol, :integer, allow_nil?: false, constraints: [min: 1, max: 1]
    attribute :editor_commit, :string, allow_nil?: false, constraints: [max_length: 40]
    attribute :editor_release, :string, allow_nil?: false, constraints: [max_length: 64]
    attribute :expires_at, :utc_datetime_usec, allow_nil?: false
    create_timestamp :inserted_at
  end

  relationships do
    belongs_to :service, Marshall.Ingress.Service, allow_nil?: false
    belongs_to :host, Marshall.Compute.Host, allow_nil?: false
  end

  identities do
    identity :gateway_release, [
      :service_id,
      :service_generation,
      :session_id,
      :editor_protocol,
      :editor_commit,
      :editor_release
    ]
  end
end
