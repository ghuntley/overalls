defmodule MarshallWeb.WorkspaceComponents do
  @moduledoc "Shared Overalls panels, headings and machine workspace navigation."
  use MarshallWeb, :html
  alias Phoenix.LiveView.JS

  # @cc [owner:ghuntley,label:product] workspace-controls-preserve-authority
  # Presentation components MUST preserve caller-provided action attributes and
  # escaped content. Navigation and badges MUST NOT authorize domain operations.
  attr :id, :string, default: nil
  attr :class, :string, default: nil
  attr :title, :string, default: nil
  attr :rest, :global
  slot :actions
  slot :inner_block, required: true
  @spec panel(map()) :: Phoenix.LiveView.Rendered.t()
  def panel(assigns) do
    ~H"""
    <section id={@id} class={["panel", @class]} {@rest}>
      <header :if={@title || @actions != []}>
        <h2 :if={@title}>{@title}</h2>
        <div :if={@actions != []} class="row">{render_slot(@actions)}</div>
      </header>
      <div class="panel-body">{render_slot(@inner_block)}</div>
    </section>
    """
  end

  attr :title, :string, required: true
  attr :subtitle, :string, default: nil
  slot :actions
  @spec heading(map()) :: Phoenix.LiveView.Rendered.t()
  def heading(assigns) do
    ~H"""
    <header class="page-heading">
      <div>
        <h1>{@title}</h1><p :if={@subtitle}>{@subtitle}</p>
      </div>
      <div :if={@actions != []} class="heading-actions">{render_slot(@actions)}</div>
    </header>
    """
  end

  attr :id, :string, default: nil
  attr :title, :string, required: true
  slot :inner_block, required: true
  slot :action
  @spec empty(map()) :: Phoenix.LiveView.Rendered.t()
  def empty(assigns) do
    ~H"""
    <div id={@id} class="empty-state">
      <h2>{@title}</h2><p>{render_slot(@inner_block)}</p>
      <div :if={@action != []} class="row actions">{render_slot(@action)}</div>
    </div>
    """
  end

  # @cc [owner:ghuntley,label:product] machine-state-label-text-and-tone
  # Every machine status label MUST name the state in text from machine_state/1
  # (Deleting, Stopping, Suspending, Resuming, Starting, or the named observed state) and carry
  # the observed state in `data-state` plus the severity in `data-tone`, decided
  # in the same clause order as the text: pending for every transition
  # (Deleting, Stopping, Suspending, Resuming, Starting, Pending, Unknown), danger for a failed
  # machine, success for a settled running machine and no tone for the neutral
  # settled states (Paused, Stopped, Deleted). Colour never carries meaning.
  @spec machine_state(map()) :: String.t()
  def machine_state(%{desired_state: :deleted}), do: dgettext("terminal", "Deleting")

  def machine_state(%{desired_state: :stopped, observed_state: :running}),
    do: dgettext("terminal", "Stopping")

  def machine_state(%{desired_state: :paused, observed_state: :running}),
    do: dgettext("terminal", "Suspending")

  def machine_state(%{desired_state: :running, observed_state: :paused}),
    do: dgettext("terminal", "Resuming")

  def machine_state(%{desired_state: :running, observed_state: state})
      when state in [:pending, :stopped], do: dgettext("terminal", "Starting")

  def machine_state(%{observed_state: state}) do
    case state do
      :pending -> dgettext("terminal", "Pending")
      :running -> dgettext("terminal", "Running")
      :stopped -> dgettext("terminal", "Stopped")
      :paused -> dgettext("terminal", "Paused")
      :failed -> dgettext("terminal", "Failed")
      :deleted -> dgettext("terminal", "Deleted")
      :unknown -> dgettext("terminal", "Unknown")
      _ -> dgettext("terminal", "Unavailable")
    end
  end

  @doc "The status-label severity tone matching machine_state/1, or nil for neutral states."
  @spec machine_tone(map()) :: String.t() | nil
  def machine_tone(%{desired_state: :deleted}), do: "pending"
  def machine_tone(%{desired_state: :stopped, observed_state: :running}), do: "pending"
  def machine_tone(%{desired_state: :paused, observed_state: :running}), do: "pending"
  def machine_tone(%{desired_state: :running, observed_state: :paused}), do: "pending"

  def machine_tone(%{desired_state: :running, observed_state: state})
      when state in [:pending, :stopped], do: "pending"

  def machine_tone(%{observed_state: :failed}), do: "danger"
  def machine_tone(%{observed_state: :running}), do: "success"
  def machine_tone(%{observed_state: state}) when state in [:pending, :unknown], do: "pending"
  def machine_tone(_vm), do: nil

  attr :vm, :map, required: true
  attr :active, :string, default: "terminal"
  # @cc [owner:ghuntley,label:security;product] workspace-agentless-image-hides-guest-controls
  # Terminal and SSH connection controls MUST render only when the
  # projected guest_capabilities grant that capability; an image without it or a
  # missing projection hides the control and shows the explanation instead.
  # Hiding is presentation only; server-side authorities refuse independently.

  # @cc [owner:ghuntley,label:product;security] workspace-host-boot-log-entry
  # Machine navigation MUST NOT carry a Boot log tab. Readers of a machine whose
  # image lacks guest SSH MUST get a Boot log link in the connection explanation,
  # since host diagnostics are their only console. The link MUST select
  # read-only host diagnostics; navigation MUST NOT grant terminal or host-file
  # authority.

  # @cc [owner:ghuntley,label:product] workspace-global-thread-entry
  # Machine workspace navigation MUST omit the machine-scoped Agents entry;
  # the global Threads navigation is the primary entry to agent work.
  @spec machine_nav(map()) :: Phoenix.LiveView.Rendered.t()
  def machine_nav(assigns) do
    ~H"""
    <nav class="machine-tabs" aria-label={dgettext("terminal", "Machine workspace")}>
      <.link
        :if={capability?(@vm, :terminal)}
        navigate={~p"/machines/#{@vm.id}"}
        aria-current={@active == "terminal" && "page"}
      >{dgettext("terminal", "Terminal")}</.link>
      <.link
        :if={@vm.permissions.manage && OverallsProtocol.ProfilePolicy.allows?(@vm.profile, :sharing)}
        navigate={~p"/machines/#{@vm.id}/access"}
        aria-current={@active == "access" && "page"}
      >{dgettext("terminal", "Access")}</.link>
      <.link
        navigate={~p"/machines/#{@vm.id}/settings"}
        aria-current={@active == "settings" && "page"}
      >{dgettext("terminal", "Settings")}</.link>
    </nav>
    """
  end

  @doc "The projected image display name shown as the machine's operating system, or nil."
  @spec operating_system(map()) :: String.t() | nil
  def operating_system(vm) do
    case Map.get(vm, :image_name) do
      name when is_binary(name) and name != "" -> name
      _ -> nil
    end
  end

  attr :vm, :map, required: true
  attr :id, :string, required: true
  # @cc [owner:ghuntley,label:product] workspace-operating-system-label
  # The operating-system label MUST show only the projected image display name
  # (`image_name`) as text. A missing or blank name MUST render no element at
  # all, never "nil" or a placeholder; the label never conveys state by colour.
  @spec os_label(map()) :: Phoenix.LiveView.Rendered.t()
  def os_label(assigns) do
    assigns = assign(assigns, :name, operating_system(assigns.vm))

    ~H"""
    <span :if={@name} id={@id} class="status-label os-label" data-tone="muted">{@name}</span>
    """
  end

  attr :vm, :map, required: true
  attr :id, :string, required: true
  # @cc [owner:ghuntley,label:product] pin-toggle-presentation
  # The pin control MUST read the caller's projected `pinned` flag only (a
  # missing flag renders as unpinned), name its state in text and
  # `aria-pressed`, and send the server-selected VM id with the displayed state
  # through the `pin` event; it MUST NOT be offered for a machine with deleted
  # intent unless the caller still holds a pin to clear. The flag never
  # authorizes the toggle; the Pins coordinator decides.
  @spec pin_toggle(map()) :: Phoenix.LiveView.Rendered.t()
  def pin_toggle(assigns) do
    assigns = assign(assigns, :pinned, pinned?(assigns.vm))

    ~H"""
    <button
      :if={@pinned || (@vm.desired_state != :deleted && @vm.observed_state != :failed)}
      type="button"
      id={@id}
      class="console-button ghost pin-toggle"
      phx-click="pin"
      phx-value-id={@vm.id}
      phx-value-pinned={to_string(@pinned)}
      aria-pressed={to_string(@pinned)}
      aria-label={
        if @pinned,
          do: dgettext("terminal", "Unpin %{name}", name: @vm.name),
          else: dgettext("terminal", "Pin %{name}", name: @vm.name)
      }
    >{if @pinned, do: dgettext("terminal", "Unpin"), else: dgettext("terminal", "Pin")}</button>
    """
  end

  attr :vm, :map, required: true
  attr :id, :string, required: true
  @doc "A text marker for a machine the caller has pinned; renders nothing otherwise."
  @spec pinned_label(map()) :: Phoenix.LiveView.Rendered.t()
  def pinned_label(assigns) do
    assigns = assign(assigns, :pinned, pinned?(assigns.vm))

    ~H"""
    <span :if={@pinned} id={@id} class="status-label pinned-label" data-tone="muted">{dgettext(
      "terminal",
      "Pinned"
    )}</span>
    """
  end

  @doc "The caller's projected pin flag; partial projections count as unpinned."
  @spec pinned?(map()) :: boolean()
  def pinned?(vm), do: Map.get(vm, :pinned, false) == true

  attr :vm, :map, required: true
  attr :connection, :map, default: nil
  attr :power_key, :string, required: true
  attr :active, :string, required: true
  # @cc [owner:ghuntley,label:security;product] workspace-editor-eligibility
  # Every editor control MUST require current projected write/profile authority,
  # Customer ownership, both desired/observed running and available image status.
  # Unsupported images MUST show a disabled control with an unsupported-image
  # explanation and no advice to create a machine; missing/unknown status MUST
  # fail closed. Rendering MUST NOT read resources or allocate accounts; the
  # displayed status MUST NOT authorize the launch route.

  # @cc [owner:ghuntley,label:product;recovery] suspended-machine-power-controls
  # Manage-authorized paused machines MUST expose Resume rather than Start and
  # retain Stop. Settled running machines MUST expose Pause; rendered controls
  # MUST submit lifecycle intent through the existing request-key boundary.
  @spec machine_header(map()) :: Phoenix.LiveView.Rendered.t()
  def machine_header(assigns) do
    assigns = assign(assigns, :editor_control, editor_control(assigns.vm))

    ~H"""
    <div id="machine-workspace-header" class="machine-workspace-header">
      <header class="machine-heading">
        <div class="machine-summary">
          <div class="machine-title">
            <h1>{@vm.name}</h1>
            <.pinned_label vm={@vm} id="machine-pinned" />
            <.os_label vm={@vm} id="machine-os" />
            <span
              id="machine-state"
              class="status-label"
              data-state={@vm.observed_state}
              data-tone={machine_tone(@vm)}
            >{machine_state(@vm)}</span>
          </div>
          <p class="machine-facts muted">
            {dgettext(
              "terminal",
              "%{value1} vCPU · %{value2} GiB memory · %{value3} GiB disk · %{value4}",
              value1: @vm.vcpu,
              value2: workspace_gib(@vm.memory_bytes),
              value3: workspace_gib(@vm.disk_bytes),
              value4: profile_name(@vm.profile)
            )}
          </p>
          <p class="machine-identity">
            <span class="muted">{dgettext("terminal", "ID")}</span>
            <code id="machine-id">{@vm.id}</code>
            <button
              type="button"
              class="console-button compact copy-button"
              data-copy-command="machine-id"
              data-copy-label={dgettext("terminal", "Machine ID")}
              aria-label={dgettext("terminal", "Copy machine ID")}
            >{dgettext("terminal", "Copy")}</button>
          </p>
        </div>
        <div class="machine-actions">
          <div class="machine-action-row">
            <.pin_toggle vm={@vm} id={"pin-#{@vm.id}"} />
            <.link
              :if={@editor_control == :available}
              id="open-vscode"
              href={~p"/machines/#{@vm.id}/code"}
              target="_blank"
              rel="noopener noreferrer"
              class="console-button machine-editor-button"
            >
              {dgettext("terminal", "Open VS Code")} <.glyph name="arrow_up_right" />
            </.link>
            <button
              :if={@editor_control in [:unavailable, :not_running]}
              id="open-vscode-disabled"
              type="button"
              disabled
              aria-describedby="vscode-unavailable"
              class="console-button machine-editor-button"
            >
              {dgettext("terminal", "Open VS Code")}
            </button>
            <div
              :if={@vm.permissions.manage && @vm.desired_state != :deleted}
              id="lifecycle-actions"
              class="row"
            >
              <Layouts.action
                :if={
                  (@vm.desired_state not in [:running, :paused] && @vm.observed_state != :paused) ||
                    @vm.observed_state == :failed
                }
                id="start-machine"
                tone="primary"
                phx-click="machine-power"
                phx-value-kind="start"
                phx-value-key={@power_key}
              >
                {dgettext("terminal", "Start machine")}
              </Layouts.action>
              <Layouts.action
                :if={@vm.desired_state == :paused || @vm.observed_state == :paused}
                id="resume-machine"
                tone="primary"
                phx-click="machine-power"
                phx-value-kind="resume"
                phx-value-key={@power_key}
              >
                {dgettext("terminal", "Resume machine")}
              </Layouts.action>
              <Layouts.action
                :if={@vm.desired_state == :running && @vm.observed_state == :running}
                id="pause-machine"
                phx-click="machine-power"
                phx-value-kind="pause"
                phx-value-key={@power_key}
              >
                {dgettext("terminal", "Pause")}
              </Layouts.action>
              <Layouts.action
                :if={@vm.desired_state in [:running, :paused]}
                id="stop-machine"
                tone="default"
                phx-click="machine-power"
                phx-value-kind="stop"
                phx-value-key={@power_key}
              >
                {dgettext("terminal", "Stop")}
              </Layouts.action>
            </div>
          </div>
          <%= if @editor_control in [:unavailable, :not_running] do %>
            <p id="vscode-unavailable" class="machine-editor-notice muted">
              <%= case @editor_control do %>
                <% :not_running -> %>
                  {dgettext("terminal", "VS Code requires a running machine.")}
                <% _ -> %>
                  {dgettext("terminal", "VS Code is temporarily unavailable for this machine.")}
              <% end %>
            </p>
          <% end %>
        </div>
      </header>
      <section
        id="machine-connect"
        phx-hook="MachineConnection"
        class="machine-connect"
        aria-labelledby="machine-connect-title"
      >
        <%!-- Collapsed while it holds commands, to keep the header short; an
             unavailable explanation (which may carry the only Boot log link)
             starts open. LiveView keeps the viewer's open/closed choice. --%>
        <details
          id="machine-connect-details"
          class="machine-connect-details"
          open={!(@connection && capability?(@vm, :ssh))}
          phx-mounted={JS.ignore_attributes(["open"])}
        >
          <summary>
            <h2 id="machine-connect-title">{dgettext("terminal", "Connect from your computer")}</h2>
          </summary>
          <%= if @connection && capability?(@vm, :ssh) do %>
            <p class="muted">
              {dgettext(
                "terminal",
                "Installs Overalls, configures SSH, and connects to this machine. On Windows the installer also installs OpenSSH 9.6 or newer and, with administrator approval, makes it the default ssh."
              )}
            </p>
            <h3 class="connection-step">{dgettext("terminal", "Install and connect")}</h3>
            <div class="connection-grid">
              <span class="connection-platform muted">{dgettext("terminal", "Linux / macOS")}</span>
              <div id="ssh-connection-commands" class="connection-command">
                <pre><code id="machine-install-command">{@connection.install}</code></pre>
                <button
                  type="button"
                  class="console-button compact copy-button"
                  data-copy-command="machine-install-command"
                  aria-label={dgettext("terminal", "Copy Linux and macOS install command")}
                >{dgettext("terminal", "Copy")}</button>
              </div>
              <span class="connection-platform muted">{dgettext("terminal", "Windows")}</span>
              <div id="machine-connect-windows" class="connection-command">
                <pre><code id="machine-install-command-windows">{@connection.install_windows}</code></pre>
                <button
                  type="button"
                  class="console-button compact copy-button"
                  data-copy-command="machine-install-command-windows"
                  aria-label={dgettext("terminal", "Copy Windows PowerShell install command")}
                >{dgettext("terminal", "Copy")}</button>
              </div>
            </div>
            <h3 class="connection-step">{dgettext("terminal", "Already installed")}</h3>
            <div class="connection-command">
              <pre><code id="machine-ssh-command">{@connection.ssh}</code></pre>
              <button
                type="button"
                class="console-button compact copy-button"
                data-copy-command="machine-ssh-command"
                aria-label={dgettext("terminal", "Copy SSH command")}
              >{dgettext("terminal", "Copy")}</button>
            </div>
          <% else %>
            <p id="machine-connect-unavailable" class="muted">
              <%= cond do %>
                <% capability?(@vm, :available) && !capability?(@vm, :ssh) -> %>
                  {dgettext(
                    "terminal",
                    "This machine's image has no guest agents yet: SSH, the browser terminal and agents are unavailable. Use"
                  )}
                  <.link
                    :if={@vm.permissions.read}
                    id="machine-boot-log"
                    navigate={~p"/machines/#{@vm.id}/terminals?view=boot-log"}
                    aria-current={@active == "boot-log" && "page"}
                  >{dgettext("terminal", "Boot log")}</.link>
                  {dgettext("terminal", "to view the read-only host console.")}
                <% !@vm.permissions.write -> %>
                  {dgettext("terminal", "SSH connection requires write access to this machine.")}
                <% @vm.profile == :inception -> %>
                  {dgettext("terminal", "Use the browser terminal for this Inception environment.")}
                <% true -> %>
                  {dgettext("terminal", "SSH connection details are temporarily unavailable.")}
              <% end %>
            </p>
          <% end %>
        </details>
        <span id="machine-copy-status" role="status" aria-live="polite" phx-update="ignore"></span>
      </section>
      <.machine_nav vm={@vm} active={@active} />
    </div>
    """
  end

  attr(:vm, :map, required: true)
  attr(:id_prefix, :string, required: true)
  attr(:variant, :atom, values: [:button, :link], default: :button)

  # @cc [owner:ghuntley,label:product] machine-editor-action-presentation
  # List editor actions MUST match the adjacent terminal's text-only treatment:
  # console-button in the Machines table, plain link with an arrow in Overview.
  # Unavailable actions MUST remain disabled and retain their explanatory text.
  @spec machine_editor_action(map()) :: Phoenix.LiveView.Rendered.t()
  def machine_editor_action(assigns) do
    assigns = assign(assigns, :editor_control, editor_control(assigns.vm))

    ~H"""
    <.link
      :if={@editor_control == :available}
      id={"#{@id_prefix}-#{@vm.id}-vscode"}
      href={~p"/machines/#{@vm.id}/code"}
      target="_blank"
      rel="noopener noreferrer"
      class={if @variant == :button, do: "console-button", else: "machine-editor-link"}
      aria-label={dgettext("terminal", "Open VS Code for %{value1}", value1: @vm.name)}
    >{dgettext("terminal", "Open VS Code")}{if @variant == :link, do: " ↗"}</.link>
    <button
      :if={@editor_control in [:unavailable, :not_running]}
      id={"#{@id_prefix}-#{@vm.id}-vscode-disabled"}
      type="button"
      disabled
      aria-describedby={"#{@id_prefix}-#{@vm.id}-vscode-reason"}
      class={if @variant == :button, do: "console-button", else: "machine-editor-link"}
    >{dgettext("terminal", "Open VS Code")}</button>
    <p
      :if={@editor_control in [:unavailable, :not_running]}
      id={"#{@id_prefix}-#{@vm.id}-vscode-reason"}
      class="machine-editor-notice muted"
      role="status"
    >
      {editor_unavailable_message(@editor_control)}
    </p>
    """
  end

  # @cc [owner:ghuntley,label:security;product] machine-editor-projection
  # Shared editor actions MUST use the finite projected eligibility state and
  # MUST render links only for available controls. Unsupported images MUST
  # hide the editor action entirely; other unavailable states may show a
  # disabled action with explanatory text. Disabled reasons are presentation
  # feedback; they MUST NOT authorize or imply a launch grant.
  @spec editor_control(map()) ::
          :available | :unsupported_image | :unavailable | :not_running | :hidden
  def editor_control(
        %{
          permissions: %{write: true},
          profile: profile,
          desired_state: desired,
          observed_state: observed
        } = vm
      )
      when desired != :deleted do
    cond do
      not OverallsProtocol.ProfilePolicy.allows?(profile, :editor) -> :hidden
      profile == :customer and not Map.get(vm, :owner, false) -> :hidden
      not capability?(vm, :editor) -> :hidden
      Map.get(vm, :editor_image_status) == :unsupported_image -> :hidden
      Map.get(vm, :editor_image_status) != :available -> :unavailable
      desired != :running or observed != :running -> :not_running
      true -> :available
    end
  end

  def editor_control(_), do: :hidden

  @spec editor_unavailable_message(atom()) :: String.t()
  def editor_unavailable_message(:not_running),
    do: dgettext("terminal", "VS Code requires a running machine.")

  def editor_unavailable_message(:unavailable),
    do: dgettext("terminal", "VS Code is temporarily unavailable.")

  def editor_unavailable_message(_),
    do: dgettext("terminal", "VS Code is unavailable for this machine.")

  @spec capability?(map(), atom()) :: boolean()
  defp capability?(vm, name) do
    case Map.get(vm, :guest_capabilities) do
      %{} = capabilities -> Map.get(capabilities, name, false) == true
      _ -> false
    end
  end

  @spec workspace_gib(non_neg_integer()) :: String.t()
  defp workspace_gib(bytes), do: :erlang.float_to_binary(bytes / 1_073_741_824, decimals: 1)

  @spec profile_name(atom()) :: String.t()
  defp profile_name(:oss), do: "OSS"
  defp profile_name(:customer), do: dgettext("terminal", "Customer")
  defp profile_name(:standard), do: dgettext("terminal", "Standard")
  defp profile_name(:inception), do: "Inception"
  defp profile_name(_), do: dgettext("terminal", "Unknown")
end
