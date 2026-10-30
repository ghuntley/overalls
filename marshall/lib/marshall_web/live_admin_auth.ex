defmodule MarshallWeb.LiveAdminAuth do
  @moduledoc "Signed-in Control room reads and fresh administrator mutation checks."
  alias Marshall.Accounts.{Security, User}
  alias MarshallWeb.AdminElevation
  use Gettext, backend: MarshallWeb.Gettext
  import Phoenix.Component
  use MarshallWeb, :verified_routes

  @read_events ~w(preview capacity filters custom zoom pause visibility reload heat rank history history-older filter tail)
  @mutation_actions Map.new(
                      for {action, events} <- [
                            {"admin_accounts",
                             ~w(set-role revoke-sessions revoke-key revoke-session revoke-grant invite delete-user reset-mfa register refresh remove)},
                            {"admin_operate",
                             ~w(evacuate control approve replan lifecycle relocate rotate-certificate admin-override redaction-enqueue redaction-pause redaction-resume redaction-cancel)},
                            {"admin_configure", ~w(configure scim-configure)},
                            {"admin_jobs", ~w(retry)}
                          ],
                          event <- events,
                          do: {event, action}
                    )

  @typep hook_result ::
           {:cont | :halt, Phoenix.LiveView.Socket.t()}
           | {:halt, map(), Phoenix.LiveView.Socket.t()}

  # @cc [owner:ghuntley,label:security] admin-live-current-authority
  # Control room views MUST install required-login checks first and recheck
  # read authority at mount and every event, message and navigation. Mutations
  # MUST require a current administrator and elevation before their callbacks;
  # demotion retains reads but MUST halt mutations. Unknown events MUST halt.
  # Refresh the session-bound actor so promotion retains administrator auditing.
  @spec on_mount(:required, map(), map(), Phoenix.LiveView.Socket.t()) :: hook_result()
  def on_mount(:required, _, _, socket) do
    case check(socket) do
      {:cont, socket} ->
        socket =
          socket
          |> Phoenix.LiveView.put_private(:admin_intent, nil)
          |> Phoenix.LiveView.attach_hook(:fresh_admin, :handle_event, fn event, params, socket ->
            case check(socket) do
              {:cont, socket} -> authorize_event(event, params, socket)
              halted -> halted
            end
          end)
          |> Phoenix.LiveView.attach_hook(:fresh_admin, :handle_info, fn _, socket ->
            check(socket)
          end)
          |> Phoenix.LiveView.attach_hook(:fresh_admin, :handle_params, fn _, uri, socket ->
            path = URI.parse(uri)

            check(
              Phoenix.LiveView.put_private(
                clear_intent(socket),
                :security_return_to,
                path.path <> if(path.query, do: "?" <> path.query, else: "")
              )
            )
          end)

        {:cont, socket}

      halted ->
        halted
    end
  end

  @spec authorize_event(String.t(), map(), Phoenix.LiveView.Socket.t()) :: hook_result()
  defp authorize_event("admin-step-up-cancel", _, socket),
    do: {:halt, %{ok: true}, clear_intent(socket)}

  defp authorize_event("admin-step-up-begin", %{"nonce" => nonce}, socket) do
    with %{challenge_id: _} = intent <- socket.private[:admin_intent],
         true <- nonce == intent.nonce,
         true <- socket.assigns.admin_authorized and AdminElevation.current?(intent, socket),
         {:ok, challenge} <- security_action(socket, :begin_verify, %{}) do
      {:halt, %{ok: true, challenge: challenge},
       Phoenix.LiveView.put_private(socket, :admin_intent, %{intent | challenge_id: challenge.id})}
    else
      _ -> {:halt, %{ok: false}, fail_intent(socket)}
    end
  end

  defp authorize_event("admin-step-up-begin", _, socket),
    do: {:halt, %{ok: false}, fail_intent(socket)}

  defp authorize_event("admin-step-up-finish", %{"nonce" => nonce, "payload" => payload}, socket) do
    with %{challenge_id: id} = intent <- socket.private[:admin_intent],
         true <- nonce == intent.nonce,
         true <- socket.assigns.admin_authorized and AdminElevation.current?(intent, socket),
         true <- valid_assertion?(payload) and payload["id"] == id,
         {:ok, %{verified: true}} <- security_action(socket, :finish_verify, payload),
         true <- Security.recent?(socket.assigns.current_user),
         true <- allowed?(intent.event, socket) do
      resume(intent, clear_intent(socket))
    else
      _ ->
        if current_intent?(socket, nonce) do
          {:halt, %{ok: false},
           Phoenix.LiveView.push_event(socket, "admin-step-up-error", %{
             message: "Verification could not be completed. Try again."
           })}
        else
          {:halt, %{ok: false}, fail_intent(socket)}
        end
    end
  end

  defp authorize_event("admin-step-up-finish", _, socket),
    do: {:halt, %{ok: false}, fail_intent(socket)}

  defp authorize_event(event, _, socket) when event in @read_events, do: {:cont, socket}

  defp authorize_event(event, params, socket) do
    action = Map.get(@mutation_actions, event)

    cond do
      is_nil(action) or not socket.assigns.admin_authorized ->
        {:halt,
         Phoenix.LiveView.put_flash(
           socket,
           :error,
           dgettext("admin_access", "Administrative changes require an administrator.")
         )}

      not Security.recent?(socket.assigns.current_user) ->
        stage_intent(event, params, socket)

      Marshall.Authorization.control_plane?(socket.assigns.current_user, action) ->
        {:cont, socket}

      true ->
        {:halt,
         Phoenix.LiveView.put_flash(
           socket,
           :error,
           dgettext("admin_access", "Administrative changes are not authorized.")
         )}
    end
  end

  @spec current_intent?(Phoenix.LiveView.Socket.t(), term()) :: boolean()
  defp current_intent?(socket, nonce) do
    case socket.private[:admin_intent] do
      %{nonce: ^nonce} = intent ->
        socket.assigns.admin_authorized and AdminElevation.current?(intent, socket)

      _ ->
        false
    end
  end

  # @cc [owner:ghuntley,label:security;concurrency] admin-elevation-one-shot-continuation
  # Successful verification MUST consume the socket-local intent before calling
  # its original view callback once with the stored parameters. Current login,
  # administrator, fixed elevation, Cedar and resource binding MUST be rechecked.
  # Browser replies MUST never select or carry administrative form parameters.
  @spec resume(AdminElevation.intent(), Phoenix.LiveView.Socket.t()) :: hook_result()
  defp resume(intent, socket) do
    case socket.view.handle_event(intent.event, intent.params, socket) do
      {:noreply, socket} -> {:halt, %{ok: true, completed: true}, socket}
      {:reply, _, socket} -> {:halt, %{ok: true, completed: true}, socket}
    end
  end

  @spec stage_intent(String.t(), map(), Phoenix.LiveView.Socket.t()) :: hook_result()
  defp stage_intent(event, params, socket) do
    with {:ok, normalized} <- AdminElevation.normalize(event, params),
         {:ok, status} <- security_action(socket, :status, %{}) do
      if status.credentials == [] do
        {:halt,
         Phoenix.LiveView.redirect(clear_intent(socket),
           to:
             ~p"/settings?#{%{return_to: socket.private[:security_return_to] || "/admin/users"}}" <>
               "#security"
         )}
      else
        intent = AdminElevation.stage(event, normalized, socket)

        if socket.private[:admin_intent] do
          {:halt,
           Phoenix.LiveView.put_flash(
             socket,
             :error,
             dgettext("admin_access", "Finish or cancel the current verification first.")
           )}
        else
          socket = Phoenix.LiveView.put_private(socket, :admin_intent, intent)

          {:halt,
           Phoenix.LiveView.push_event(socket, "admin-step-up-open", %{
             nonce: intent.nonce,
             action: AdminElevation.action_label(event)
           })}
        end
      end
    else
      _ ->
        {:halt,
         Phoenix.LiveView.put_flash(
           socket,
           :error,
           dgettext("admin_access", "Invalid administrative request.")
         )}
    end
  end

  @spec allowed?(String.t(), Phoenix.LiveView.Socket.t()) :: boolean()
  defp allowed?(event, socket) do
    socket.assigns.admin_authorized and
      Marshall.Authorization.control_plane?(
        socket.assigns.current_user,
        Map.fetch!(@mutation_actions, event)
      )
  end

  @spec security_action(Phoenix.LiveView.Socket.t(), atom(), map()) ::
          {:ok, map()} | {:error, term()}
  defp security_action(socket, operation, payload) do
    User
    |> Ash.ActionInput.for_action(:security, %{operation: operation, payload: payload},
      actor: socket.assigns.current_user
    )
    |> Ash.run_action()
  end

  @spec clear_intent(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  defp clear_intent(socket) do
    socket
    |> Phoenix.LiveView.put_private(:admin_intent, nil)
    |> Phoenix.LiveView.push_event("admin-step-up-close", %{})
  end

  @spec fail_intent(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  defp fail_intent(socket),
    do:
      socket
      |> clear_intent()
      |> Phoenix.LiveView.put_flash(
        :error,
        "This action expired or your access changed. Try it again."
      )

  @spec valid_assertion?(term()) :: boolean()
  defp valid_assertion?(payload) when is_map(payload) do
    fields = ~w(id raw_id authenticator_data signature client_data_json)

    Map.keys(payload) -- fields == [] and map_size(payload) == 5 and
      OverallsProtocol.uuid?(payload["id"]) and
      Enum.all?(tl(fields), fn key ->
        is_binary(payload[key]) and byte_size(payload[key]) in 1..16_384
      end)
  end

  defp valid_assertion?(_), do: false

  @spec check(Phoenix.LiveView.Socket.t()) :: hook_result()
  defp check(socket) do
    with true <-
           Marshall.Authorization.control_plane?(socket.assigns[:current_user], "admin_read"),
         %User{deleted_at: nil, active: true} = user <-
           Security.current(socket.assigns.current_user.id) do
      {:cont,
       assign(socket,
         current_user: Security.bind(user, socket.private.login_jti),
         admin_authorized: user.administrator
       )}
    else
      _ -> {:halt, Phoenix.LiveView.redirect(socket, to: ~p"/machines")}
    end
  end
end
