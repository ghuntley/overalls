defmodule MarshallWeb.MachineProvisioningLive do
  @moduledoc "Authorized receipt page for asynchronous machine provisioning."
  use MarshallWeb, :live_view

  alias Marshall.Threads

  on_mount({MarshallWeb.LiveUserAuth, :live_user_required})

  @impl true
  def mount(%{"id" => thread_id}, _session, socket) do
    socket = assign(socket, thread_id: thread_id, thread: nil, error: nil)
    if connected?(socket), do: Process.send_after(self(), :refresh, 250)
    {:ok, refresh(socket)}
  end

  @impl true
  def handle_params(%{"id" => thread_id}, _uri, socket) do
    {:noreply, assign(socket, thread_id: thread_id) |> refresh()}
  end

  @impl true
  def handle_info(:refresh, socket) do
    Process.send_after(self(), :refresh, 1000)
    {:noreply, refresh(socket)}
  end

  @impl true
  def handle_event("retry", _params, socket) do
    case Threads.retry_provisioning(%{thread_id: socket.assigns.thread_id},
           actor: socket.assigns.current_user
         ) do
      {:ok, thread} -> {:noreply, assign(socket, thread: thread, error: nil)}
      _ -> {:noreply, assign(socket, error: dgettext("machines", "Retry is unavailable."))}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <main id="machine-provisioning" class="stack">
        <h1>{dgettext("machines", "Setting up your machine")}</h1>
        <p :if={@error} role="alert">{@error}</p>
        <button :if={@thread && @thread.status == :failed} type="button" phx-click="retry">
          {dgettext("machines", "Retry setup")}
        </button>
        <p :if={!@error and @thread}>
          {dgettext(
            "machines",
            "Provisioning is in progress. This page will open the machine when it is ready."
          )}
        </p>
      </main>
    </Layouts.app>
    """
  end

  # @cc [owner:ghuntley,label:security;durability] provisioning-receipt-redirect
  # The receipt MUST resolve the thread through the current authenticated actor
  # and MUST navigate to a machine detail route only after the thread supplies
  # its server-bound machine_id.
  defp refresh(socket) do
    case Threads.get_thread(%{thread_id: socket.assigns.thread_id},
           actor: socket.assigns.current_user
         ) do
      {:ok, %{machine_id: machine_id} = thread} when is_binary(machine_id) ->
        push_navigate(assign(socket, thread: thread), to: ~p"/machines/#{machine_id}")

      {:ok, thread} ->
        assign(socket, thread: thread, error: nil)

      _ ->
        assign(socket,
          thread: nil,
          error: dgettext("machines", "Provisioning request unavailable.")
        )
    end
  end
end
