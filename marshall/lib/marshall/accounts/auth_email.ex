# @cc [owner:ghuntley,label:security] auth-email-minimal-durable-payload
# Delivery jobs MUST contain record identifiers rather than recipient/token data.
# The encrypted payload MUST not be decrypted by default or copied to audit
# history; expiry cleanup MUST physically remove expired outbox records.
defmodule Marshall.Accounts.AuthEmail do
  @moduledoc "Encrypted, short-lived magic-link outbox. Jobs contain record IDs only."
  use Ash.Resource,
    otp_app: :marshall,
    domain: Marshall.Accounts,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Marshall.Authorization.AshAuthorizer],
    extensions: [AshCloak, AshOban]

  postgres do
    table "account_auth_emails"
    repo Marshall.Repo

    custom_indexes do
      index [:recipient_fingerprint, :inserted_at]
      index [:expires_at]
    end
  end

  cedar do
    internal [:read, :enqueue, :deliver, :purge]
  end

  cloak do
    vault(Marshall.Vault)
    attributes([:payload])
    decrypt_by_default([])
    encrypt_nil?(false)
  end

  oban do
    triggers do
      trigger :deliver do
        action :deliver
        queue :mail
        where expr(status == :pending)
        scheduler_cron "* * * * *"
        max_attempts 8
        worker_module_name Marshall.Accounts.Workers.DeliverAuthEmail
        scheduler_module_name Marshall.Accounts.Workers.ScheduleAuthEmail
        default_actor %Marshall.Authorization.SystemActor{purpose: :compute}
        actor_persister :none
        log_errors? false
        log_final_error? false
      end

      trigger :purge do
        action :purge
        queue :mail
        scheduler_cron "* * * * *"
        where expr(expires_at <= fragment("(statement_timestamp() AT TIME ZONE 'UTC')"))
        worker_module_name Marshall.Accounts.Workers.PurgeAuthEmail
        scheduler_module_name Marshall.Accounts.Workers.ScheduleAuthEmailPurge
        default_actor %Marshall.Authorization.SystemActor{purpose: :compute}
        actor_persister :none
        log_errors? false
        log_final_error? false
      end
    end
  end

  actions do
    defaults [:read]

    create :enqueue do
      accept [:payload, :token_fingerprint, :recipient_fingerprint, :expires_at]

      change fn changeset, _ ->
        Ash.Changeset.force_change_attribute(
          changeset,
          :inserted_at,
          Marshall.Compute.Ledger.now()
        )
      end

      change run_oban_trigger(:deliver)
    end

    update :deliver do
      accept []
      transaction? true
      require_atomic? false
      change Marshall.Accounts.DeliverAuthEmail
    end

    destroy :purge do
      change filter(expr(expires_at <= fragment("(statement_timestamp() AT TIME ZONE 'UTC')")))
    end
  end

  attributes do
    uuid_primary_key :id
    attribute :payload, :map, sensitive?: true
    attribute :token_fingerprint, :string, allow_nil?: false, sensitive?: true
    attribute :recipient_fingerprint, :string, allow_nil?: false, sensitive?: true
    attribute :expires_at, :utc_datetime_usec, allow_nil?: false

    attribute :status, :atom,
      allow_nil?: false,
      default: :pending,
      constraints: [one_of: [:pending, :delivered, :expired]]

    create_timestamp :inserted_at
  end

  identities do
    identity :one_delivery_per_token, [:token_fingerprint]
  end
end
