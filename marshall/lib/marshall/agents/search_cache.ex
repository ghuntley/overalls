defmodule Marshall.Agents.SearchCache do
  @moduledoc "Shared successful public search projection with a fixed freshness window."
  use Ash.Resource,
    otp_app: :marshall,
    domain: Marshall.Agents,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Marshall.Authorization.AshAuthorizer]

  postgres do
    table "agent_search_cache"
    repo Marshall.Repo
  end

  cedar do
    internal [:read]
  end

  actions do
    defaults [:read]
  end

  attributes do
    attribute :key, :string, primary_key?: true, allow_nil?: false
    attribute :result, :map, allow_nil?: false
    attribute :fetched_at, :utc_datetime_usec, allow_nil?: false
  end
end
