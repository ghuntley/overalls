defmodule Marshall.Inference.Daily do
  @moduledoc "Owner/provider/model daily totals of reported usage, with unknowns counted explicitly."
  use Ash.Resource,
    otp_app: :marshall,
    domain: Marshall.Inference,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Marshall.Authorization.AshAuthorizer]

  postgres do
    table "inference_daily"
    repo Marshall.Repo

    custom_indexes do
      index [:owner_id, :day]
      index [:day, :id]
    end
  end

  cedar do
    internal [:read, :record, :add, :purge]
  end

  actions do
    defaults [:read]

    create :record do
      accept [
        :day,
        :owner_id,
        :provider,
        :model,
        :requests,
        :unknown_requests,
        :input_tokens,
        :output_tokens
      ]
    end

    update :add do
      accept [:requests, :unknown_requests, :input_tokens, :output_tokens]
    end

    destroy :purge
  end

  attributes do
    uuid_primary_key :id
    attribute :day, :date, allow_nil?: false
    attribute :provider, :atom, allow_nil?: false, constraints: [one_of: [:openai, :anthropic]]
    attribute :model, :string, allow_nil?: false, constraints: [max_length: 256]
    attribute :requests, :integer, allow_nil?: false, constraints: [min: 0]
    attribute :unknown_requests, :integer, allow_nil?: false, constraints: [min: 0]
    attribute :input_tokens, :decimal, allow_nil?: false
    attribute :output_tokens, :decimal, allow_nil?: false
  end

  relationships do
    belongs_to :owner, Marshall.Accounts.User, allow_nil?: false
  end

  identities do
    identity :bucket, [:day, :owner_id, :provider, :model]
  end
end
