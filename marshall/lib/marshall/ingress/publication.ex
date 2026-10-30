defmodule Marshall.Ingress.Publication do
  @moduledoc "Durable per-zone ordering of complete DNS publication snapshots."
  use Ash.Resource,
    otp_app: :marshall,
    domain: Marshall.Ingress,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Marshall.Authorization.AshAuthorizer]

  postgres do
    table "ingress_publications"
    repo Marshall.Repo

    check_constraints do
      check_constraint :revision, "ingress_publication_revision", check: "revision >= 0"
    end
  end

  cedar do
    internal [:read, :initialize, :advance, :snapshot]
  end

  actions do
    defaults [:read]

    create :initialize do
      accept [:zone]
    end

    update :advance do
      accept [:revision]
    end

    action :snapshot, :map do
      argument :token, :string, allow_nil?: false, sensitive?: true, constraints: [max_length: 80]
      argument :zone, :string, allow_nil?: false, constraints: [max_length: 189, trim?: false]
      run Marshall.Ingress.Publications
    end
  end

  attributes do
    attribute :zone, :string,
      primary_key?: true,
      allow_nil?: false,
      constraints: [min_length: 1, max_length: 189]

    attribute :revision, :integer, allow_nil?: false, default: 0, constraints: [min: 0]
  end
end
