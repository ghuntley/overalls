# @cc [owner:ghuntley,label:product] image-immutable-content-fields
# After registration, resource actions MUST NOT change image identity, manifest,
# architecture or minimum sizes. Availability configuration may change enabled
# status and MUST retain an audited history.
defmodule Marshall.Compute.Image do
  use Ash.Resource,
    otp_app: :marshall,
    domain: Marshall.Compute,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Marshall.Authorization.AshAuthorizer],
    extensions: [AshPaperTrail.Resource]

  @type editor_image_status :: :available | :unsupported_image | :unavailable
  @type guest_capabilities :: %{
          available: boolean(),
          readiness: boolean(),
          trust: boolean(),
          ssh: boolean(),
          terminal: boolean(),
          workspace: boolean(),
          flush: boolean(),
          agents: boolean(),
          editor: boolean(),
          inception: boolean(),
          android_sdk: boolean(),
          adb: boolean(),
          android_emulator: boolean(),
          android_display: boolean()
        }
  @type editor_capability :: %{
          editor_protocol: 1,
          editor_commit: String.t(),
          editor_release: String.t()
        }

  postgres do
    table "compute_images"
    repo Marshall.Repo
  end

  cedar do
    internal [:read, :register, :configure]
  end

  paper_trail do
    metadata :actor_kind, :atom, allow_nil?: true
    metadata :actor_id, :uuid, allow_nil?: true
    sensitive_attributes :ignore
    change_tracking_mode :changes_only
    store_action_name? true
    ignore_attributes [:inserted_at, :updated_at]
    version_extensions authorizers: [Marshall.Authorization.AshAuthorizer]
    mixin Marshall.Authorization.VersionMapping
  end

  actions do
    defaults [:read]

    create :register do
      accept [:name, :manifest]
      change Marshall.Compute.Changes.ValidateImage
    end

    update :configure do
      accept [:enabled]
    end
  end

  attributes do
    attribute :id, :string, primary_key?: true, allow_nil?: false
    attribute :name, :string, allow_nil?: false, constraints: [min_length: 1, max_length: 128]
    attribute :manifest, :map, allow_nil?: false
    attribute :architecture, :atom, allow_nil?: false, constraints: [one_of: [:x86_64]]
    attribute :minimum_memory_bytes, :integer, allow_nil?: false
    attribute :minimum_disk_bytes, :integer, allow_nil?: false
    attribute :enabled, :boolean, allow_nil?: false, default: true
    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  # @cc [owner:ghuntley,label:security;protocol] image-editor-exact-release
  # Editor capability MUST require a validated manifest matching the stored image
  # ID and the exact protocol/commit/release configured for its validated target.
  # A tuple approved only for another target MUST NOT authorize it. Valid legacy or different
  # releases MUST return unsupported_image; missing/corrupt image or configuration
  # MUST return unavailable. Catalog enabled status MUST NOT revoke an existing
  # image's editor capability. This pure helper MUST NOT grant user authority.
  @spec editor_capability(term(), term()) ::
          {:ok, editor_capability()} | {:error, :unsupported_image | :unavailable}
  def editor_capability(%{id: id, manifest: manifest}, configured) do
    with {:ok, releases} <- Marshall.Editor.Releases.decode(configured),
         {:ok, %{id: ^id} = validated} <- OverallsProtocol.ImageManifest.validate(manifest) do
      case {Marshall.Editor.Releases.for_image(validated, releases), Map.get(validated, :editor)} do
        {{:ok, approved}, actual} when approved == actual ->
          {:ok,
           %{
             editor_protocol: approved.protocol,
             editor_commit: approved.commit,
             editor_release: approved.release
           }}

        _ ->
          {:error, :unsupported_image}
      end
    else
      _ -> {:error, :unavailable}
    end
  end

  def editor_capability(_, _), do: {:error, :unavailable}

  # @cc [owner:ghuntley,label:security;protocol] image-guest-agents-exact-manifest
  # Guest agent capability MUST come only from a validated manifest matching the
  # stored image ID: version-4 images carry the Linux agent set, version-5
  # firmware images declare `none` or `windows-v1`, and version-6 native images
  # carry their matching native agent set. Version-7 Windows editor images carry
  # only the separate windows-editor-v1 set. A missing, corrupt or
  # mismatched manifest MUST return unavailable, never a default agent set. This
  # pure helper grants no authority.
  @spec guest_agents_capability(term()) ::
          {:ok, OverallsProtocol.ImageManifest.guest_agents()} | {:error, :unavailable}
  def guest_agents_capability(%{id: id, manifest: manifest}) do
    case OverallsProtocol.ImageManifest.validate(manifest) do
      {:ok, %{id: ^id} = validated} ->
        {:ok, OverallsProtocol.ImageManifest.guest_agents(validated)}

      _ ->
        {:error, :unavailable}
    end
  end

  def guest_agents_capability(_), do: {:error, :unavailable}

  # @cc [owner:ghuntley,label:capacity;protocol] image-readiness-budget-by-agent-set
  # readiness_budget_ms/2 MUST derive the readiness deadline from the validated
  # image row's agent set and profile. Missing, corrupt or mismatched images
  # MUST return nil so callers retain their existing unknown-image fallback.
  @spec readiness_budget_ms(term(), atom()) :: pos_integer() | nil
  def readiness_budget_ms(image, profile) when is_atom(profile) do
    case guest_agents_capability(image) do
      {:ok, agents} -> OverallsProtocol.GuestAgents.readiness_budget_ms(agents, profile)
      {:error, :unavailable} -> nil
    end
  end

  @doc "Finite per-capability guest facts of an image row for projections and refusals; fails closed."
  # @cc [owner:ghuntley,label:security;product] image-guest-capabilities-from-table
  # guest_capabilities/1 MUST derive every boolean from OverallsProtocol.GuestAgents'
  # table using the complete validated, row-bound image identity. Native images
  # MUST additionally match the exact reviewed admission identity; an agent-set
  # name or kernel provenance alone grants no capability. Missing, corrupt or
  # mismatched manifests MUST return all-false (available: false). Valid but
  # unapproved native identities remain available with all capabilities false.
  # Surfaces branch on these booleans, never on the agent set name.
  @spec guest_capabilities(term()) :: guest_capabilities()
  def guest_capabilities(image) do
    with %{id: id, manifest: manifest} <- image,
         {:ok, %{id: ^id} = validated} <- OverallsProtocol.ImageManifest.validate(manifest) do
      capabilities =
        OverallsProtocol.GuestAgents.capabilities(
          OverallsProtocol.ImageManifest.guest_agents(validated),
          validated
        )

      %{
        available: true,
        readiness: capabilities.readiness,
        trust: capabilities.trust,
        ssh: capabilities.ssh,
        terminal: capabilities.terminal,
        workspace: capabilities.workspace,
        flush: capabilities.flush,
        agents: capabilities.agents,
        editor: capabilities.editor,
        inception: capabilities.inception,
        android_sdk: capabilities.android_sdk,
        adb: capabilities.adb,
        android_emulator: capabilities.android_emulator,
        android_display: capabilities.android_display
      }
    else
      _ ->
        %{
          available: false,
          readiness: false,
          trust: false,
          ssh: false,
          terminal: false,
          workspace: false,
          flush: false,
          agents: false,
          editor: false,
          inception: false,
          android_sdk: false,
          adb: false,
          android_emulator: false,
          android_display: false
        }
    end
  end

  # @cc [owner:ghuntley,label:security;protocol] preset-source-image-capability
  # A launch preset image MUST have a valid row-bound manifest declaring source
  # protocol 2 and current workspace capability. Missing or unqualified identity
  # MUST return false; a guest-agent set alone is insufficient.
  @spec workspace_source_capable?(term()) :: boolean()
  def workspace_source_capable?(%{id: id, manifest: manifest} = image) do
    match?(
      {:ok, %{id: ^id, workspace_source_version: 2}},
      OverallsProtocol.ImageManifest.validate(manifest)
    ) and
      guest_capabilities(image).workspace
  end

  def workspace_source_capable?(_), do: false

  @type size_request :: %{
          required(:architecture) => atom(),
          required(:memory_bytes) => pos_integer(),
          required(:disk_bytes) => pos_integer(),
          optional(atom()) => term()
        }

  # @cc [owner:ghuntley,label:product;capacity] image-size-requirements-single-rule
  # requirements_met?/2 is the one image sizing rule: a request MUST match the
  # image architecture and carry at least the image's minimum memory and disk
  # bytes. Transactional admission and every pre-admission form check MUST use
  # this predicate rather than restating thresholds; a pre-admission check never
  # replaces the transactional refusal.
  @spec requirements_met?(
          %{
            required(:architecture) => atom(),
            required(:minimum_memory_bytes) => pos_integer(),
            required(:minimum_disk_bytes) => pos_integer(),
            optional(atom()) => term()
          },
          size_request()
        ) :: boolean()
  def requirements_met?(image, request) do
    image.architecture == request.architecture and
      request.memory_bytes >= image.minimum_memory_bytes and
      request.disk_bytes >= image.minimum_disk_bytes
  end

  # @cc [owner:ghuntley,label:capacity] image-default-shape-rounding
  # For image minima within execution limits, omitted defaults MUST meet those
  # minima through whole MiB memory and whole GiB disk rounding. Minima above the
  # execution limits MUST remain oversized so admission rejects them, never clamp
  # below image requirements. This helper MUST NOT alter explicitly supplied sizes
  # or substitute for transactional Ash admission.
  @spec default_shape(%{
          required(:minimum_memory_bytes) => pos_integer(),
          required(:minimum_disk_bytes) => pos_integer(),
          optional(atom()) => term()
        }) ::
          %{vcpu: pos_integer(), memory_bytes: pos_integer(), disk_bytes: pos_integer()}
  def default_shape(image) do
    %{
      vcpu: 1,
      memory_bytes: max(512, div(image.minimum_memory_bytes + 1_048_575, 1_048_576)) * 1_048_576,
      disk_bytes:
        max(2, div(image.minimum_disk_bytes + 1_073_741_823, 1_073_741_824)) * 1_073_741_824
    }
  end
end
