defmodule Marshall.Threads.Generation do
  @moduledoc "Retained machine and agent binding for one user-thread generation."
  use Ash.Resource,
    otp_app: :marshall,
    domain: Marshall.Threads,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Marshall.Authorization.AshAuthorizer]

  postgres do
    table "thread_generations"
    repo Marshall.Repo

    custom_indexes do
      index [:thread_id, :ordinal], unique: true
      index [:thread_id, :machine_key], unique: true
      index [:agent_thread_id]
    end
  end

  cedar do
    internal [:read, :open, :bind, :state]
  end

  actions do
    defaults [:read]

    create :open do
      accept [
        :thread_id,
        :ordinal,
        :machine_key,
        :machine_id,
        :agent_root_id,
        :agent_thread_id,
        :status,
        :failure_reason,
        :archived_at
      ]
    end

    update :bind do
      accept [
        :machine_id,
        :agent_root_id,
        :agent_thread_id,
        :status,
        :failure_reason,
        :archived_at
      ]
    end

    update :state do
      accept [:status, :failure_reason, :archived_at]
    end
  end

  attributes do
    uuid_v7_primary_key :id
    attribute :thread_id, :uuid, allow_nil?: false
    attribute :ordinal, :integer, allow_nil?: false, constraints: [min: 1]

    # @cc [owner:ghuntley,label:durability;recovery] generation-key-identity
    # A retained generation MUST keep the machine admission key that created it.
    # Reopened generations receive a different key, and transcript selection MUST
    # never identify a generation by the mutable current thread binding alone.
    attribute :machine_key, :string,
      allow_nil?: false,
      constraints: [min_length: 1, max_length: 160]

    attribute :machine_id, :uuid
    attribute :agent_root_id, :uuid
    attribute :agent_thread_id, :uuid

    attribute :status, :atom,
      allow_nil?: false,
      default: :pending,
      constraints: [one_of: [:pending, :provisioning, :ready, :failed, :deleting, :archived]]

    attribute :failure_reason, :atom,
      constraints: [
        one_of: [
          :invalid_machine_spec,
          :invalid_profile,
          :capacity,
          :machine_unavailable,
          :provision_failed,
          :agent_unavailable,
          :unknown
        ]
      ]

    attribute :archived_at, :utc_datetime_usec
    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  alias Marshall.Compute.Ledger

  @spec open!(Marshall.Threads.Thread.t(), pos_integer()) :: t()
  def open!(thread, ordinal) when is_integer(ordinal) and ordinal >= 1 do
    Ledger.create!(__MODULE__, :open, %{
      thread_id: thread.id,
      ordinal: ordinal,
      machine_key: thread.machine_key,
      machine_id: thread.machine_id,
      agent_root_id: thread.agent_root_id,
      agent_thread_id: thread.agent_thread_id,
      status: thread.status,
      failure_reason: thread.failure_reason,
      archived_at: thread.archived_at
    })
  end

  @spec open_next!(Marshall.Threads.Thread.t()) :: t()
  def open_next!(thread) do
    ordinal =
      __MODULE__
      |> Ledger.read!(thread_id: thread.id)
      |> Enum.map(& &1.ordinal)
      |> Enum.max(fn -> 0 end)
      |> Kernel.+(1)

    open!(thread, ordinal)
  end

  @spec sync!(Marshall.Threads.Thread.t()) :: t() | nil
  def sync!(thread) do
    case Ledger.read!(__MODULE__, thread_id: thread.id, machine_key: thread.machine_key) do
      [%__MODULE__{} = generation] ->
        Ledger.update!(generation, :bind, %{
          machine_id: thread.machine_id,
          agent_root_id: thread.agent_root_id,
          agent_thread_id: thread.agent_thread_id,
          status: thread.status,
          failure_reason: thread.failure_reason,
          archived_at: thread.archived_at
        })

      [] ->
        nil

      _ ->
        raise "multiple thread generation rows"
    end
  end

  @spec ensure_current!(Marshall.Threads.Thread.t()) :: t() | nil
  def ensure_current!(thread) do
    case Ledger.read!(__MODULE__, thread_id: thread.id, machine_key: thread.machine_key) do
      [%__MODULE__{} = generation] -> generation
      [] -> open!(thread, 1)
      _ -> raise "multiple thread generation rows"
    end
  end
end
