# @cc [owner:ghuntley,label:security;persistence] vm-workspace-source-immutable
# A VM MAY carry at most one public repository source, recorded only by admission
# in its allocation transaction and never updated or destroyed. Only egress-capable
# profiles may hold one; clones MUST NOT inherit it.
defmodule Marshall.Compute.WorkspaceSource do
  @moduledoc "The immutable source-v2 identity whose guest performs checkout."
  use Ash.Resource,
    otp_app: :marshall,
    domain: Marshall.Compute,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Marshall.Authorization.AshAuthorizer]

  alias OverallsProtocol.WorkspaceSource, as: Source
  @type t :: %__MODULE__{}
  postgres do
    table "compute_workspace_sources"
    repo Marshall.Repo

    check_constraints do
      check_constraint :provider, "valid_workspace_provider",
        check: "provider IN ('github','gitlab','codeberg','bitbucket')"

      check_constraint :revision, "valid_workspace_revision",
        check: "revision->>'kind' IN ('default','ref','tag','commit','change')"
    end
  end

  cedar do
    internal [:read, :record]
  end

  actions do
    defaults [:read]

    create :record do
      accept [:vm_id, :provider, :namespace, :repository, :revision]

      change fn changeset, _ ->
        source =
          Map.new([:provider, :namespace, :repository, :revision], fn key ->
            {key, Ash.Changeset.get_attribute(changeset, key)}
          end)

        if Source.valid?(source) do
          Ash.Changeset.force_change_attribute(
            changeset,
            :revision,
            Source.encode(source)["revision"]
          )
        else
          Ash.Changeset.add_error(changeset,
            field: :revision,
            message: "invalid workspace source"
          )
        end
      end
    end
  end

  attributes do
    attribute :provider, :atom,
      allow_nil?: false,
      constraints: [one_of: [:github, :gitlab, :codeberg, :bitbucket]]

    attribute :namespace, {:array, :string}, allow_nil?: false
    attribute :repository, :string, allow_nil?: false, constraints: [max_length: 100]
    attribute :revision, :map, allow_nil?: false
    create_timestamp :inserted_at
  end

  relationships do
    belongs_to :vm, Marshall.Compute.VirtualMachine,
      primary_key?: true,
      allow_nil?: false,
      attribute_writable?: true
  end

  @doc "Validate the stored source through the sole current protocol schema."
  @spec protocol(t()) :: Source.t()
  def protocol(%__MODULE__{} = source) do
    {:ok, value} =
      Source.decode(%{
        "version" => 2,
        "provider" => Atom.to_string(source.provider),
        "namespace" => source.namespace,
        "repository" => source.repository,
        "revision" => source.revision
      })

    value
  end
end
