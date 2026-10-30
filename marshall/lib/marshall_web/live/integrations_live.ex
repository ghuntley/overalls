defmodule MarshallWeb.IntegrationsLive do
  use MarshallWeb, :live_view
  alias Marshall.Galileo
  on_mount({MarshallWeb.AuthenticationPrivacy, :default})
  on_mount({MarshallWeb.LiveUserAuth, :live_user_required})

  @github_transient_phases [:revoking, :draining, :refreshing]

  @impl true
  @spec mount(map(), map(), Phoenix.LiveView.Socket.t()) :: {:ok, Phoenix.LiveView.Socket.t()}
  def mount(_, _, socket) do
    {:ok, socket |> assign(integrations: []) |> reset_form() |> refresh()}
  end

  # @cc [owner:ghuntley,label:security] browser-integration-secret-write-only
  # Secret form fields MUST be cleared after every attempt and MUST never be
  # reflected in diagnostics, listings or receipts. Stored values display only
  # as their kind; the write-only boundary lives in the domain. Each attempt
  # MUST replace password inputs so browser-local values cannot survive a patch
  # whose server-side form values were already empty.
  @impl true
  @spec handle_event(String.t(), map(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_event("add", %{"integration" => params}, socket) when is_map(params) do
    user = socket.assigns.current_user

    result =
      Galileo.configure_integration(
        %{
          name: params["name"],
          comment: params["comment"] || "",
          target: blank_to_nil(params["target"]),
          strip_prefix: blank_to_nil(params["strip_prefix"]),
          headers: header_params(params),
          peer: Map.get(params, "peer") == "true",
          peer_vm_id: blank_to_nil(params["peer_vm_id"]),
          team_id: blank_to_nil(params["team_id"]),
          idempotency_key: "web:" <> Ash.UUID.generate()
        },
        actor: user
      )

    socket = reset_form(socket)

    case result do
      {:ok, integration} ->
        {:noreply,
         socket
         |> put_flash(
           :info,
           dgettext("integrations", "Integration %{value1} saved.", value1: integration.name)
         )
         |> refresh()}

      {:error, _} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           dgettext(
             "integrations",
             "Could not save this integration. Check the name, HTTPS target and header values."
           )
         )}
    end
  end

  def handle_event("remove", %{"name" => name}, socket) do
    case Galileo.remove_integration(%{name: name}, actor: socket.assigns.current_user) do
      {:ok, _} ->
        {:noreply,
         socket |> put_flash(:info, dgettext("integrations", "Integration removed.")) |> refresh()}

      {:error, _} ->
        {:noreply,
         socket
         |> put_flash(:error, dgettext("integrations", "Could not remove this integration."))
         |> refresh()}
    end
  end

  def handle_event("attach", %{"name" => name, "attachment" => %{"vm_id" => vm_id}}, socket) do
    case Galileo.attach_integration(%{name: name, vm_id: vm_id},
           actor: socket.assigns.current_user
         ) do
      {:ok, _} ->
        {:noreply,
         socket |> put_flash(:info, dgettext("integrations", "Machine attached.")) |> refresh()}

      {:error, _} ->
        {:noreply,
         socket
         |> put_flash(:error, dgettext("integrations", "Could not attach that machine."))
         |> refresh()}
    end
  end

  def handle_event("detach", %{"name" => name, "vm-id" => vm_id}, socket) do
    case Galileo.detach_integration(%{name: name, vm_id: vm_id},
           actor: socket.assigns.current_user
         ) do
      {:ok, _} ->
        {:noreply,
         socket |> put_flash(:info, dgettext("integrations", "Machine detached.")) |> refresh()}

      {:error, _} ->
        {:noreply,
         socket
         |> put_flash(:error, dgettext("integrations", "Could not detach that machine."))
         |> refresh()}
    end
  end

  def handle_event("github-disconnect", _params, socket) do
    case Marshall.GitHub.disconnect(socket.assigns.current_user) do
      {:ok, _status} ->
        {:noreply,
         socket
         |> put_flash(:info, dgettext("integrations", "GitHub disconnected."))
         |> refresh()}

      {:error, _reason} ->
        {:noreply,
         socket
         |> put_flash(:error, dgettext("integrations", "Could not disconnect GitHub."))
         |> refresh()}
    end
  end

  def handle_event("github-detach", %{"github_machine" => %{"vm_id" => vm_id}}, socket) do
    github_machine(socket, vm_id, true)
  end

  def handle_event("github-attach", %{"vm-id" => vm_id}, socket) do
    github_machine(socket, vm_id, false)
  end

  def handle_event(_, _, socket),
    do: {:noreply, put_flash(socket, :error, dgettext("integrations", "Invalid request."))}

  @impl true
  @spec handle_info(:refresh_github, Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_info(:refresh_github, socket),
    do: {:noreply, socket |> assign(github_poll_pending: false) |> refresh_github()}

  defp github_machine(socket, vm_id, excluded?) do
    case Marshall.GitHub.set_excluded(socket.assigns.current_user, vm_id, excluded?) do
      {:ok, _status} ->
        {:noreply,
         socket
         |> put_flash(:info, github_machine_message(excluded?, :success))
         |> refresh()}

      {:error, _reason} ->
        {:noreply,
         socket
         |> put_flash(:error, github_machine_message(excluded?, :error))
         |> refresh()}
    end
  end

  defp github_machine_message(true, :success),
    do: dgettext("integrations", "Machine detached.")

  defp github_machine_message(false, :success),
    do: dgettext("integrations", "Machine attached.")

  defp github_machine_message(true, :error),
    do: dgettext("integrations", "Could not update the GitHub connection.")

  defp github_machine_message(false, :error),
    do: dgettext("integrations", "Could not update the GitHub connection.")

  defp refresh(socket) do
    socket = refresh_github(socket)

    case Galileo.list_integrations(%{}, actor: socket.assigns.current_user) do
      {:ok, integrations} ->
        assign(socket, integrations: integrations)

      {:error, _} ->
        socket
        |> assign(integrations: [])
        |> put_flash(
          :error,
          dgettext("integrations", "Integrations are temporarily unavailable.")
        )
    end
  end

  # @cc [owner:ghuntley,label:product;observability] github-transient-phase-follows-settlement
  # While the owner's GitHub phase is revoking, draining or refreshing, a
  # connected view MUST re-read that status at most once per second, holding at
  # most one pending timer, until the phase leaves those states, so Disconnect
  # reaches "Disconnected" without a reload once the asynchronous revocation
  # settles. Stable phases MUST NOT schedule re-reads, and the re-read MUST NOT
  # reload the Galileo integration list or clear form state.
  @spec refresh_github(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  defp refresh_github(socket) do
    github =
      case Marshall.GitHub.status(socket.assigns.current_user) do
        {:ok, status} ->
          status

        {:error, _} ->
          %{phase: :unavailable, github_login: nil, exclusions: [], configured: false}
      end

    socket = assign(socket, github: github)

    if connected?(socket) and github.phase in @github_transient_phases and
         not Map.get(socket.assigns, :github_poll_pending, false) do
      Process.send_after(self(), :refresh_github, 1_000)
      assign(socket, github_poll_pending: true)
    else
      socket
    end
  end

  @spec github_state(atom()) :: String.t()
  defp github_state(:connected), do: dgettext("integrations", "Connected")
  defp github_state(:ready), do: dgettext("integrations", "Connected")
  defp github_state(:disconnected), do: dgettext("integrations", "Disconnected")
  defp github_state(:authorizing), do: dgettext("integrations", "Awaiting GitHub authorization")
  defp github_state(:draining), do: dgettext("integrations", "Finishing active GitHub requests")
  defp github_state(:refreshing), do: dgettext("integrations", "Refreshing GitHub connection")
  defp github_state(:reconnect_required), do: dgettext("integrations", "Reconnect required")
  defp github_state(:revoking), do: dgettext("integrations", "Disconnecting GitHub")
  defp github_state(_), do: dgettext("integrations", "Temporarily unavailable")

  defp reset_form(socket) do
    assign(
      socket,
      form_generation: Map.get(socket.assigns, :form_generation, 0) + 1,
      form:
        to_form(
          %{
            "name" => "",
            "comment" => "",
            "target" => "",
            "strip_prefix" => "",
            "bearer" => "",
            "basic" => "",
            "header_name" => "",
            "header_value" => "",
            "peer" => "false",
            "peer_vm_id" => "",
            "team_id" => ""
          },
          as: :integration
        )
    )
  end

  defp header_params(params) do
    static =
      case {blank_to_nil(params["header_name"]), blank_to_nil(params["header_value"])} do
        {nil, nil} -> []
        {name, value} -> [%{kind: :static, name: name, value: value}]
      end

    bearer =
      case blank_to_nil(params["bearer"]) do
        nil -> []
        token -> [%{kind: :bearer, name: "authorization", value: token}]
      end

    basic =
      case blank_to_nil(params["basic"]) do
        nil -> []
        credentials -> [%{kind: :basic, name: "authorization", value: credentials}]
      end

    if params["bearer"] != "" && params["basic"] != "",
      do: [%{kind: :static, name: "invalid", value: "conflicting credentials"}],
      else: static ++ bearer ++ basic
  end

  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: value

  @impl true
  @spec render(map()) :: Phoenix.LiveView.Rendered.t()
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={%{user: @current_user}}
      time_zone={@time_zone}
      now={@now}
      compute={true}
      active="integrations"
    >
      <section id="integrations-page" class="stack">
        <UI.heading
          title={dgettext("integrations", "Integrations")}
          subtitle={
            dgettext(
              "integrations",
              "Named endpoints your machines reach at https://NAME.integration.internal. Credentials are injected at the edge and are never readable from a machine."
            )
          }
        />
        <article id="github-com-integration" class="panel stack">
          <header>
            <h2>github-com</h2>
            <span id="github-com-state" class="status-label">{github_state(@github.phase)}</span>
          </header>
          <p><code>https://com-github.integration.internal</code></p>
          <p>
            {dgettext(
              "integrations",
              "Connect your GitHub account for Git, pull requests, Actions, releases and other development workflows. GitHub credentials stay at the edge."
            )}
          </p>
          <p>
            {dgettext(
              "integrations",
              "Your machines automatically use your connected GitHub identity. Collaborators using a shared machine can use its owner's GitHub permissions. Detached machines retain anonymous public GitHub access."
            )}
          </p>
          <p :if={@github.github_login} id="github-com-identity">
            {dgettext("integrations", "Connected as %{login}", login: @github.github_login)}
          </p>
          <div class="row">
            <.form for={%{}} id="github-com-connect" action="/auth/github-com/start" method="post">
              <button class="console-button primary" type="submit" disabled={!@github.configured}>
                {dgettext("integrations", "Connect GitHub")}
              </button>
            </.form>
            <button
              :if={@github.phase not in [:disconnected, :unavailable]}
              id="github-com-disconnect"
              phx-click="github-disconnect"
              data-confirm={dgettext("integrations", "Disconnect GitHub from your machines?")}
              class="console-button danger"
            >
              {dgettext("integrations", "Disconnect GitHub")}
            </button>
          </div>
          <%!-- Detach and Attach re-render the list; keep the owner's open panel. --%>
          <details id="github-com-machines" phx-mounted={JS.ignore_attributes(["open"])}>
            <summary>
              {dgettext("integrations", "Machines excluded from your GitHub identity")}
            </summary>
            <div class="stack">
              <.form
                for={to_form(%{"vm_id" => ""}, as: :github_machine)}
                id="github-com-detach"
                phx-submit="github-detach"
                class="field-row"
              >
                <.input
                  name="github_machine[vm_id]"
                  value=""
                  label={dgettext("integrations", "Machine UUID")}
                  required
                />
                <button class="console-button" type="submit">{dgettext("integrations", "Detach")}</button>
              </.form>
              <div :for={vm_id <- @github.exclusions} id={"github-com-excluded-#{vm_id}"} class="row">
                <code class="break">{vm_id}</code>
                <button
                  phx-click="github-attach"
                  phx-value-vm-id={vm_id}
                  class="console-button compact"
                >
                  {dgettext("integrations", "Attach")}
                </button>
              </div>
            </div>
          </details>
        </article>
        <p :if={@integrations == []} class="empty-state">
          {dgettext(
            "integrations",
            "No integrations yet. Add one below to give your machines a named connection to an API or to another machine."
          )}
        </p>
        <div id="integrations" class="stack">
          <article
            :for={integration <- @integrations}
            id={"integration-#{integration.id}"}
            class="panel"
          >
            <header>
              <h2 class="ident break"><code>{integration.name}.integration.internal</code></h2>
              <div class="row">
                <span class="status-label">{if integration.team_id,
                  do: dgettext("integrations", "Team-owned integration"),
                  else: dgettext("integrations", "Personal integration")}</span>
                <button
                  id={"remove-integration-#{integration.id}"}
                  phx-click="remove"
                  phx-value-name={integration.name}
                  data-confirm={dgettext("integrations", "Remove this integration?")}
                  class="console-button danger"
                >
                  {dgettext("integrations", "Remove")}
                </button>
              </div>
            </header>
            <div class="panel-body">
              <.kv>
                <:item :if={integration.target} title={dgettext("integrations", "Target")}>
                  <span class="break">{integration.target}</span>
                </:item>
                <:item :if={!integration.target} title={dgettext("integrations", "Peer machine")}>
                  <code class="break">{integration.peer_vm_id}</code>
                </:item>
                <:item title={dgettext("integrations", "Owner")}>
                  {if integration.team_id,
                    do: dgettext("integrations", "Team %{team}", team: integration.team_id),
                    else: dgettext("integrations", "Personal integration")}
                </:item>
                <:item :if={integration.comment != ""} title={dgettext("integrations", "Comment")}>
                  <span class="break">{integration.comment}</span>
                </:item>
                <:item
                  :if={integration.strip_prefix}
                  title={dgettext("integrations", "Strips prefix")}
                >
                  <code>{integration.strip_prefix}</code>
                </:item>
              </.kv>
              <h3>{dgettext("integrations", "Injected credentials")}</h3>
              <div id={"integration-headers-#{integration.id}"}>
                <p :if={integration.headers == []} class="muted">
                  {dgettext("integrations", "No injected headers.")}
                </p>
                <.kv :if={integration.headers != []}>
                  <:item :for={header <- integration.headers} title={header.name}>
                    <span class="muted">{dgettext("integrations", "**** (write-only)")}</span>
                  </:item>
                </.kv>
              </div>
              <h3>{dgettext("integrations", "Machines with access")}</h3>
              <div id={"integration-attachments-#{integration.id}"}>
                <p :if={integration.attachments == []} class="muted">
                  {if integration.team_id,
                    do:
                      dgettext(
                        "integrations",
                        "No explicit attachments. Current team members' machines have access."
                      ),
                    else:
                      dgettext(
                        "integrations",
                        "No machines have access. Attach a machine to use this integration."
                      )}
                </p>
                <div :if={integration.attachments != []} class="table-flow">
                  <table>
                    <thead>
                      <tr>
                        <th class="width-auto">{dgettext("integrations", "Machine")}</th>
                        <th class="width-min">
                          <span class="sr-only">{dgettext("integrations", "Actions")}</span>
                        </th>
                      </tr>
                    </thead>
                    <tbody>
                      <tr
                        :for={attachment <- integration.attachments}
                        id={"integration-attachment-#{attachment.id}"}
                      >
                        <td class="break"><code>{attachment.vm_id}</code></td>
                        <td>
                          <button
                            phx-click="detach"
                            phx-value-name={integration.name}
                            phx-value-vm-id={attachment.vm_id}
                            class="console-button compact"
                          >
                            {dgettext("integrations", "Detach")}
                          </button>
                        </td>
                      </tr>
                    </tbody>
                  </table>
                </div>
              </div>
              <.form
                for={to_form(%{"vm_id" => ""}, as: :attachment)}
                id={"attach-form-#{integration.id}"}
                phx-submit="attach"
                class="field-row"
              >
                <input type="hidden" name="name" value={integration.name} />
                <.input
                  id={"attachment-vm-#{integration.id}"}
                  name="attachment[vm_id]"
                  value=""
                  label={dgettext("integrations", "Attach a machine by ID")}
                  placeholder={dgettext("integrations", "Machine UUID")}
                />
                <button class="console-button">{dgettext("integrations", "Attach")}</button>
              </.form>
            </div>
          </article>
        </div>
        <.form for={@form} id="integration-form" phx-submit="add" class="panel stack">
          <h2>{dgettext("integrations", "Add an integration")}</h2>
          <p class="muted">
            {dgettext(
              "integrations",
              "Name the endpoint and point it at an HTTPS API, or mark it as a peer connection to another machine. Secrets are write-only: they are stored for injection and never shown again."
            )}
          </p>
          <div class="grid">
            <.input
              field={@form[:name]}
              label={dgettext("integrations", "Name")}
              placeholder={dgettext("integrations", "example-integration")}
            />
            <.input
              field={@form[:comment]}
              label={dgettext("integrations", "Comment")}
              placeholder={dgettext("integrations", "Short description for guest reflection")}
            />
            <.input
              field={@form[:target]}
              label={dgettext("integrations", "HTTPS target")}
              placeholder="https://api.example.com"
            />
          </div>
          <h3>{dgettext("integrations", "Credentials")}</h3>
          <div class="grid">
            <.input
              id={"integration-bearer-#{@form_generation}"}
              field={@form[:bearer]}
              label={dgettext("integrations", "Bearer token")}
              type="password"
            />
            <.input
              id={"integration-basic-#{@form_generation}"}
              field={@form[:basic]}
              label={dgettext("integrations", "Basic user:pass")}
              type="password"
            />
          </div>
          <div class="grid">
            <.input
              field={@form[:header_name]}
              label={dgettext("integrations", "Static header name")}
              placeholder={dgettext("integrations", "x-api-token")}
            />
            <.input
              id={"integration-header-value-#{@form_generation}"}
              field={@form[:header_value]}
              label={dgettext("integrations", "Static header value")}
              type="password"
            />
          </div>
          <details class="integration-options">
            <summary>
              {dgettext("integrations", "Routing, team ownership and peer connections")}
            </summary>
            <div class="stack">
              <div class="grid">
                <.input
                  field={@form[:strip_prefix]}
                  label={dgettext("integrations", "Strip prefix")}
                  placeholder="/api/v3"
                />
                <.input
                  field={@form[:team_id]}
                  label={dgettext("integrations", "Team ID")}
                  placeholder={dgettext("integrations", "Team-owned integration")}
                />
              </div>
              <div class="grid">
                <.input
                  field={@form[:peer]}
                  label={dgettext("integrations", "Peer integration")}
                  type="checkbox"
                />
                <.input
                  field={@form[:peer_vm_id]}
                  label={dgettext("integrations", "Peer machine ID")}
                  placeholder={dgettext("integrations", "Required for peer integrations")}
                />
              </div>
            </div>
          </details>
          <div class="row actions">
            <button type="submit" class="console-button primary">{dgettext(
              "integrations",
              "Save integration"
            )}</button>
          </div>
        </.form>
      </section>
    </Layouts.app>
    """
  end
end
