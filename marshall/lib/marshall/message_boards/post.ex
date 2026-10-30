defmodule Marshall.MessageBoards.Post do
  @moduledoc "A bounded post with explicit machine and user-thread attribution."
  use Ash.Resource,
    otp_app: :marshall,
    domain: Marshall.MessageBoards.Domain,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Marshall.Authorization.AshAuthorizer]

  @type t :: %__MODULE__{}
  postgres do
    table "message_board_posts"
    repo Marshall.Repo
    migration_defaults id: "nil", inserted_at: "nil", updated_at: "nil"

    identity_index_names board_author_request:
                           "message_board_posts_board_id_author_id_request_key_index"

    references do
      reference :board, on_delete: :delete
      reference :author, on_delete: :delete
      reference :vm, on_delete: :delete
      reference :thread, on_delete: :delete
    end

    custom_indexes do
      index [:board_id, :inserted_at]
      index [:vm_id]
      index [:thread_id]
      index [:root_id, :inserted_at]
    end
  end

  cedar do
    internal [:destroy, :read, :post]
  end

  actions do
    defaults [:read, :destroy]

    create :post do
      accept [:board_id, :author_id, :vm_id, :thread_id, :root_id, :request_key, :body]
    end
  end

  attributes do
    uuid_primary_key :id
    attribute :board_id, :uuid, allow_nil?: false
    attribute :author_id, :uuid, allow_nil?: false
    attribute :vm_id, :uuid
    attribute :thread_id, :uuid
    attribute :root_id, :uuid, allow_nil?: false

    attribute :request_key, :string,
      allow_nil?: false,
      constraints: [min_length: 1, max_length: 128]

    attribute :body, :string,
      allow_nil?: false,
      sensitive?: true,
      constraints: [min_length: 1, max_length: 65_536]

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  relationships do
    belongs_to :board, Marshall.MessageBoards.Board do
      define_attribute? false
      source_attribute :board_id
    end

    belongs_to :author, Marshall.Accounts.User do
      define_attribute? false
      source_attribute :author_id
    end

    belongs_to :vm, Marshall.Compute.VirtualMachine do
      define_attribute? false
      source_attribute :vm_id
    end

    belongs_to :thread, Marshall.Threads.Thread do
      define_attribute? false
      source_attribute :thread_id
    end
  end

  identities do
    identity :board_author_request, [:board_id, :author_id, :request_key]
  end
end
