defmodule MarshallWeb.Admin.RedactionLive do
  use MarshallWeb, :live_view
  import Ecto.Query

  on_mount({MarshallWeb.AuthenticationPrivacy, :default})
  on_mount({MarshallWeb.LiveUserAuth, :live_user_required})
  on_mount({MarshallWeb.LiveAdminAuth, :required})

  @impl true
  def mount(_, _, socket) do
    {:ok,
     assign(socket, runs: [], unavailable?: false, request_id: Ash.UUID.generate()) |> refresh()}
  end

  @impl true
  def handle_event("redaction-enqueue", _, socket) do
    case Marshall.Redaction.enqueue(:all_inactive, socket.assigns.current_user) do
      {:ok, _id} ->
        {:noreply,
         socket
         |> put_flash(:info, dgettext("admin_audit", "Inactive thread scrub queued."))
         |> refresh()}

      {:error, _} ->
        {:noreply,
         put_flash(socket, :error, dgettext("admin_audit", "The scrub could not be queued."))}
    end
  end

  def handle_event("redaction-" <> action, %{"id" => id}, socket)
      when action in ["pause", "resume", "cancel"] do
    with {:ok, run} <-
           Ash.get(Marshall.Redaction.Run, id,
             actor: Marshall.Authorization.SystemActor.compute()
           ),
         {:ok, _} <-
           Ash.update(run, %{},
             action: String.to_existing_atom(action),
             actor: Marshall.Authorization.SystemActor.compute()
           ) do
      {:noreply,
       socket |> put_flash(:info, dgettext("admin_audit", "Redaction run updated.")) |> refresh()}
    else
      _ ->
        {:noreply,
         put_flash(
           socket,
           :error,
           dgettext("admin_audit", "The redaction run could not be updated.")
         )}
    end
  end

  defp refresh(socket) do
    runs =
      from(r in "redaction_runs",
        order_by: [desc: r.inserted_at],
        limit: 50,
        select: %{
          id: r.id,
          state: r.state,
          profile_digest: r.profile_digest,
          processed: r.processed,
          changed: r.changed,
          inserted_at: r.inserted_at
        }
      )
      |> Marshall.Repo.all()

    assign(socket, runs: runs, unavailable?: false)
  rescue
    _ -> assign(socket, runs: [], unavailable?: true)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={%{user: @current_user}}
      time_zone={@time_zone}
      now={@now}
      compute={true}
      active="admin"
      admin_active="redaction"
    >
      <section id="admin-redaction" class="stack">
        <header class="row">
          <h1>{dgettext("admin_audit", "Thread redaction")}</h1>
          <button id="redaction-enqueue" class="console-button primary" phx-click="redaction-enqueue">{dgettext(
            "admin_audit",
            "Scrub inactive threads"
          )}</button>
        </header>
        <p class="muted">
          {dgettext(
            "admin_audit",
            "Text in prompts, model output, and tool results is scrubbed in bounded background batches. Attachments are not inspected."
          )}
        </p>
        <p :if={@unavailable?}>{dgettext("admin_audit", "Redaction history is unavailable.")}</p>
        <div id="redaction-runs">
          <div :for={run <- @runs} id={"redaction-run-#{run.id}"} class="panel kv">
            <span>#{run.id}</span><span>{run.state}</span>
            <span>{dgettext("admin_audit", "Processed %{count}", count: run.processed)}</span><span>{dgettext(
              "admin_audit",
              "Changed %{count}",
              count: run.changed
            )}</span>
            <span class="muted">{dgettext("admin_audit", "Profile %{digest}",
              digest: run.profile_digest
            )}</span>
            <span class="row">
              <button :if={run.state == :running} phx-click="redaction-pause" phx-value-id={run.id}>{dgettext(
                "admin_audit",
                "Pause"
              )}</button>
              <button :if={run.state == :paused} phx-click="redaction-resume" phx-value-id={run.id}>{dgettext(
                "admin_audit",
                "Resume"
              )}</button>
              <button
                :if={run.state in [:queued, :running, :paused]}
                phx-click="redaction-cancel"
                phx-value-id={run.id}
              >{dgettext("admin_audit", "Cancel")}</button>
            </span>
          </div>
        </div>
      </section>
    </Layouts.app>
    """
  end
end
