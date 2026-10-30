defmodule Marshall.Threads.ReadMarker do
  @moduledoc """
  A reader's position in one thread's retained transcript (ADR-0222).

  One row per user and agent transcript: reopening a thread binds a fresh
  agent thread whose sequences restart, so its marker starts again at zero
  instead of hiding new events behind an old generation's position. The row
  stores only identifiers and an integer; never transcript content.
  """
  use Ash.Resource,
    otp_app: :marshall,
    domain: Marshall.Threads,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Marshall.Authorization.AshAuthorizer]

  postgres do
    table "thread_read_markers"
    repo Marshall.Repo

    check_constraints do
      check_constraint :position, "thread_read_marker_position", check: "position >= 0"
    end

    custom_indexes do
      index [:user_id, :thread_id]
    end
  end

  cedar do
    control_plane "provision", [:mark_read]
    internal [:read, :record, :advance]
  end

  actions do
    defaults [:read]

    create :record do
      accept [:user_id, :thread_id, :agent_thread_id, :position]
    end

    # Callers MUST hold the marker's advisory lock and pass a larger position;
    # Marshall.Threads.ReadMarkers is the only writer.
    update :advance do
      accept [:position]
    end

    action :mark_read, :map do
      argument :thread_id, :uuid, allow_nil?: false
      argument :position, :integer, allow_nil?: false, constraints: [min: 0, max: 2_147_483_647]
      run Marshall.Threads.ReadMarkers
    end
  end

  attributes do
    uuid_v7_primary_key :id
    attribute :user_id, :uuid, allow_nil?: false
    attribute :thread_id, :uuid, allow_nil?: false
    attribute :agent_thread_id, :uuid, allow_nil?: false
    attribute :position, :integer, allow_nil?: false, default: 0, constraints: [min: 0]
    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  identities do
    identity :one_per_reader_transcript, [:user_id, :agent_thread_id]
  end
end
