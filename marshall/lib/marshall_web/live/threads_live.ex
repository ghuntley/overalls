defmodule MarshallWeb.ThreadsLive do
  @moduledoc "Workspace-wide user threads backed by automatically provisioned machines."
  use MarshallWeb, :live_view

  alias Marshall.{Compute, Threads}
  alias Marshall.Accounts.TimeZones
  alias MarshallWeb.{MachineDefaults, ThreadCommands, WorkspaceComponents}

  on_mount({MarshallWeb.LiveUserAuth, :live_user_required})

  @type socket :: Phoenix.LiveView.Socket.t()
  @type user :: Marshall.Accounts.User.t()
  @type thread :: Threads.Thread.t()

  @impl true
  @spec mount(map(), map(), socket()) :: {:ok, socket()}
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(
        page_title: dgettext("agents", "Threads"),
        threads_empty: true,
        threads_available: true,
        activity_empty: true,
        selected: nil,
        generations: [],
        generations_available: true,
        selected_generation: nil,
        generation_current: true,
        events_empty: true,
        events_available: true,
        generation_query_error: nil,
        catalog: %{images: []},
        form: to_form(default_form(), as: :thread),
        thread_defaults_seeded: false,
        error: nil,
        detail_error: nil,
        activity_filter: "all",
        activity_time_filter: "all",
        activity_owner_filter: "all",
        activity_team_filter: "all",
        activity_query: "",
        activity_team_options: [],
        thread_query: "",
        thread_filter: "all",
        thread_cursor: nil,
        thread_next: nil,
        thread_page_empty: false,
        thread_matches_empty: true,
        can_write: false,
        can_manage: false,
        share_open: false,
        share_form: to_form(%{"email" => "", "role" => "viewer"}, as: :access),
        share_request_key: Ash.UUID.generate(),
        share_error: nil,
        grant_owner: nil,
        grant_cursor: nil,
        grant_next: nil,
        grants_available: false,
        grants_empty: true,
        prompt_request_key: Ash.UUID.generate(),
        prompt_form: to_form(%{"text" => ""}, as: :prompt),
        collaboration_mode: :work,
        controls_available: false,
        work_busy: false,
        pending_question: nil,
        latest_plan: nil,
        question_form: to_form(%{}, as: :answers),
        question_answers: %{},
        control_request_key: Ash.UUID.generate(),
        thread_dialog: nil,
        context_info: nil,
        context_available: false,
        skills: [],
        managed_skills: [],
        skills_available: false,
        skill_query: nil,
        selected_skills: [],
        skill_form: to_form(%{"url" => "", "revision" => "", "subdirectory" => "."}, as: :skill)
      )
      |> stream_configure(:activity_threads, dom_id: &"activity-thread-#{&1.id}")
      |> stream(:threads, [])
      |> stream(:activity_threads, [])
      |> stream(:events, [])
      |> stream(:thread_grants, [])

    # handle_params/3 always follows mount and performs the first refresh.
    if connected?(socket), do: Process.send_after(self(), :refresh_threads, 2_000)
    {:ok, socket}
  end

  @impl true
  @spec handle_params(map(), String.t(), socket()) :: {:noreply, socket()}
  def handle_params(params, _uri, socket) do
    selected_id = params["id"]

    {:noreply,
     socket
     |> assign(
       selected_id: selected_id,
       selected_generation_ordinal: parse_generation_ordinal(params["generation"]),
       generation_query_error: generation_query_error(params["generation"]),
       thread_cursor: nil,
       selected_skills:
         if(socket.assigns.live_action == :new and socket.assigns[:selected_id] != selected_id,
           do: [],
           else: socket.assigns.selected_skills
         )
     )
     |> refresh()}
  end

  @impl true
  @spec handle_info(:refresh_threads, socket()) :: {:noreply, socket()}
  def handle_info(:refresh_threads, socket) do
    Process.send_after(self(), :refresh_threads, 2_000)
    {:noreply, refresh(socket)}
  end

  @impl true
  @spec handle_event(String.t(), map(), socket()) :: {:noreply, socket()}
  def handle_event("validate", %{"thread" => params}, socket) when is_map(params) do
    {:noreply,
     assign(socket,
       form: to_form(Map.merge(socket.assigns.form.params, params), as: :thread),
       error: nil
     )}
  end

  def handle_event("create", %{"thread" => params}, socket) when is_map(params) do
    values = Map.merge(socket.assigns.form.params, params)
    socket = assign(socket, form: to_form(values, as: :thread))

    case ThreadCommands.parse(values["objective"] || "") do
      {:prompt, text} ->
        create_thread(socket, Map.put(values, "objective", text))

      {:command, mode, task} when mode in [:plan, :work] and task != "" ->
        create_thread(
          socket,
          Map.merge(values, %{"objective" => task, "collaboration_mode" => Atom.to_string(mode)})
        )

      {:command, command, ""} ->
        {:noreply, run_command(socket, command)}

      {:error, reason} ->
        {:noreply, assign(socket, error: error_message(reason))}
    end
  end

  # @cc [owner:ghuntley,label:security] selected-thread-actions
  # Missing or unavailable thread detail MUST refuse lifecycle and prompt events
  # without a domain mutation. Available detail MUST still use current domain
  # authorization; the cached selection is only a resource identifier.
  def handle_event(event, _params, %{assigns: %{selected: nil}} = socket)
      when event in ["prompt", "retry", "archive", "delete", "reopen", "thread_share"] do
    {:noreply, assign(socket, error: error_message(socket.assigns.detail_error || :not_found))}
  end

  # @cc [owner:ghuntley,label:recovery;security] prompt-request-key-stability
  # A prompt form MUST reuse its request key while LiveView retries or re-renders
  # the submission, then rotate it only after an accepted prompt.
  def handle_event("prompt", %{"prompt" => %{"text" => text}}, socket) when is_binary(text) do
    socket = assign(socket, prompt_form: to_form(%{"text" => text}, as: :prompt))

    case ThreadCommands.parse(text) do
      {:prompt, text} ->
        {:noreply, submit_prompt(socket, text, nil)}

      {:command, mode, task} when mode in [:plan, :work] and task != "" ->
        {:noreply, submit_prompt(socket, task, mode)}

      {:command, command, ""} ->
        {:noreply, run_command(socket, command)}

      {:error, reason} ->
        {:noreply, assign(socket, error: error_message(reason))}
    end
  end

  def handle_event("validate_prompt", %{"prompt" => params}, socket) when is_map(params) do
    {:noreply, assign(socket, prompt_form: to_form(params, as: :prompt), error: nil)}
  end

  def handle_event("thread_command", %{"command" => name}, socket) when is_binary(name) do
    case ThreadCommands.parse("/" <> name) do
      {:command, command, ""} -> {:noreply, run_command(socket, command)}
      _ -> {:noreply, assign(socket, error: error_message(:unknown_command))}
    end
  end

  def handle_event("collaboration_mode", %{"collaboration" => %{"mode" => mode}}, socket)
      when mode in ["plan", "work"] do
    {:noreply, run_command(socket, if(mode == "plan", do: :plan, else: :work))}
  end

  def handle_event("close_thread_dialog", _params, socket),
    do: {:noreply, assign(socket, thread_dialog: nil)}

  def handle_event("reload_context", _params, socket) do
    {:noreply,
     control_action(
       socket,
       &Threads.reload_context/2,
       %{},
       dgettext("agents", "Context reload queued.")
     )}
  end

  def handle_event("validate_questions", %{"answers" => answers}, socket) when is_map(answers),
    do: {:noreply, assign(socket, question_answers: answers)}

  def handle_event(
        "answer_questions",
        %{"answers" => answers, "question_id" => question_id},
        socket
      )
      when is_map(answers) and is_binary(question_id) do
    socket = assign(socket, question_answers: answers)

    {:noreply,
     control_action(
       socket,
       &Threads.answer_questions/2,
       %{question_id: question_id, answers: answers},
       dgettext("agents", "Answers submitted.")
     )}
  end

  def handle_event("implement_plan", %{"plan_id" => plan_id}, socket) when is_binary(plan_id) do
    {:noreply,
     control_action(
       socket,
       &Threads.implement_plan/2,
       %{plan_id: plan_id},
       dgettext("agents", "Implementation queued.")
     )}
  end

  def handle_event("revise_plan", %{"plan_id" => plan_id}, socket) do
    case socket.assigns.latest_plan do
      %{id: ^plan_id} ->
        {:noreply, socket |> run_command(:plan) |> push_event("thread-focus-composer", %{})}

      _ ->
        {:noreply, assign(socket, error: error_message(:stale_plan))}
    end
  end

  # @cc [owner:ghuntley,label:product;security] new-thread-skill-selection
  # Before a machine exists, skill metadata cannot be read from a guest context.
  # A new-thread skill search MUST therefore retain the exact bounded source name
  # as a pending selection, survive the periodic refresh, and flow into create;
  # existing-thread searches continue to use the authorized catalog returned by
  # the Threads domain.
  def handle_event("skill_search", %{"query" => query}, %{assigns: %{live_action: :new}} = socket)
      when is_binary(query) do
    query = query |> String.trim() |> String.slice(0, 128)

    skills =
      if query == "" do
        []
      else
        [
          %{
            id: query,
            name: query,
            description:
              dgettext(
                "agents",
                "Select this skill from the workspace catalog when the machine starts."
              ),
            path: dgettext("agents", "Workspace skill"),
            enabled: true
          }
        ]
      end

    {:noreply, assign(socket, skill_query: query, skills: skills, skills_available: query != "")}
  end

  def handle_event("skill_search", %{"query" => query}, socket) when is_binary(query) do
    {:noreply, socket |> assign(skill_query: String.slice(query, 0, 100)) |> refresh_skills()}
  end

  def handle_event("dismiss_skill_search", _params, socket),
    do: {:noreply, assign(socket, skill_query: nil)}

  def handle_event("select_skill", %{"id" => id}, socket) when is_binary(id) do
    skill = Enum.find(socket.assigns.skills, &(skill_value(&1, :id) == id))

    can_select = socket.assigns.can_write or socket.assigns.live_action == :new

    if (can_select and skill) && skill_value(skill, :enabled, true) do
      selected =
        Enum.uniq_by(socket.assigns.selected_skills ++ [skill], &skill_value(&1, :id))
        |> Enum.take(20)

      {:noreply,
       socket
       |> assign(selected_skills: selected, skill_query: nil, thread_dialog: nil)
       |> push_event("thread-skill-selected", %{})}
    else
      {:noreply, assign(socket, error: error_message(:forbidden))}
    end
  end

  def handle_event("remove_selected_skill", %{"id" => id}, socket),
    do:
      {:noreply,
       assign(socket,
         selected_skills:
           Enum.reject(socket.assigns.selected_skills, &(skill_value(&1, :id) == id))
       )}

  def handle_event("validate_skill", %{"skill" => params}, socket) when is_map(params),
    do: {:noreply, assign(socket, skill_form: to_form(params, as: :skill))}

  def handle_event("install_skill", %{"skill" => params}, socket) when is_map(params) do
    socket = assign(socket, skill_form: to_form(params, as: :skill))

    {:noreply,
     control_action(
       socket,
       &Threads.install_skill/2,
       %{
         url: params["url"],
         revision: blank_to_nil(params["revision"]),
         subdirectory: params["subdirectory"]
       },
       dgettext("agents", "Skill installation queued."),
       :idempotency_key
     )}
  end

  def handle_event("update_skill", %{"update" => %{"installation_id" => id} = params}, socket) do
    {:noreply,
     control_action(
       socket,
       &Threads.update_skill/2,
       %{installation_id: id, revision: blank_to_nil(params["revision"])},
       dgettext("agents", "Skill update queued."),
       :idempotency_key
     )}
  end

  def handle_event("update_skill", %{"id" => id}, socket),
    do:
      {:noreply,
       control_action(
         socket,
         &Threads.update_skill/2,
         %{installation_id: id},
         dgettext("agents", "Skill update queued."),
         :idempotency_key
       )}

  def handle_event("set_skill_enabled", %{"id" => id, "enabled" => enabled}, socket)
      when enabled in ["true", "false"],
      do:
        {:noreply,
         control_action(
           socket,
           &Threads.set_skill_enabled/2,
           %{installation_id: id, enabled: enabled == "true"},
           dgettext("agents", "Skill availability updated."),
           :idempotency_key
         )}

  def handle_event("remove_skill", %{"id" => id}, socket),
    do:
      {:noreply,
       control_action(
         socket,
         &Threads.remove_skill/2,
         %{installation_id: id},
         dgettext("agents", "Managed skill removed."),
         :idempotency_key
       )}

  def handle_event("retry", _params, socket) do
    case Threads.retry_provisioning(%{thread_id: socket.assigns.selected.id},
           actor: socket.assigns.current_user
         ) do
      {:ok, _} ->
        {:noreply,
         socket |> put_flash(:info, dgettext("agents", "Provisioning will retry.")) |> refresh()}

      {:error, reason} ->
        {:noreply, assign(socket, error: error_message(reason))}
    end
  end

  def handle_event("archive", _params, socket) do
    case Threads.archive_thread(%{thread_id: socket.assigns.selected.id},
           actor: socket.assigns.current_user
         ) do
      {:ok, _} ->
        {:noreply,
         socket
         |> put_flash(
           :info,
           dgettext(
             "agents",
             "Archiving requested. The machine will be deleted before archival completes."
           )
         )
         |> push_navigate(to: ~p"/threads")}

      {:error, reason} ->
        {:noreply, assign(socket, error: error_message(reason))}
    end
  end

  def handle_event("delete", _params, socket) do
    case Threads.delete_thread(%{thread_id: socket.assigns.selected.id},
           actor: socket.assigns.current_user
         ) do
      {:ok, _} ->
        {:noreply,
         socket
         |> put_flash(:info, dgettext("agents", "Thread deletion requested."))
         |> push_navigate(to: ~p"/threads")}

      {:error, reason} ->
        {:noreply, assign(socket, error: error_message(reason))}
    end
  end

  def handle_event("reopen", _params, socket) do
    case Threads.reopen_thread(%{thread_id: socket.assigns.selected.id},
           actor: socket.assigns.current_user
         ) do
      {:ok, thread} ->
        {:noreply,
         socket
         |> put_flash(:info, dgettext("agents", "Thread reopened; provisioning a new machine."))
         |> push_navigate(to: ~p"/threads/#{thread.id}")}

      {:error, reason} ->
        {:noreply, assign(socket, error: error_message(reason))}
    end
  end

  def handle_event(
        "thread_filter",
        %{"filter" => %{"query" => query, "status" => status}},
        socket
      )
      when is_binary(query) and status in ["all", "active", "archived"] do
    {:noreply,
     socket
     |> assign(
       thread_query: String.slice(query, 0, 200),
       thread_filter: status,
       thread_cursor: nil
     )
     |> refresh()}
  end

  # @cc [owner:ghuntley,label:product;durability] thread-index-keyset-controls
  # Thread index and activity navigation MUST advance the authorized keyset
  # cursor returned by Threads.list_thread_page. A page change MUST preserve
  # the domain's bounded result and never fetch an unbounded list in LiveView.
  def handle_event("threads_next", _params, %{assigns: %{thread_next: nil}} = socket),
    do: {:noreply, socket}

  def handle_event("threads_next", _params, socket) do
    {:noreply, socket |> assign(thread_cursor: socket.assigns.thread_next) |> refresh()}
  end

  def handle_event("threads_first", _params, socket),
    do: {:noreply, socket |> assign(thread_cursor: nil) |> refresh()}

  def handle_event("toggle_share", _params, socket) do
    {:noreply, socket |> assign(share_open: !socket.assigns.share_open) |> refresh()}
  end

  def handle_event("validate_access", %{"access" => params}, socket) when is_map(params) do
    {:noreply, assign(socket, share_form: to_form(params, as: :access), share_error: nil)}
  end

  def handle_event("edit_access", %{"email" => email, "role" => role}, socket)
      when is_binary(email) and role in ["viewer", "operator", "manager", "revoked"] do
    {:noreply,
     assign(socket, share_form: to_form(%{"email" => email, "role" => role}, as: :access))}
  end

  # @cc [owner:ghuntley,label:security;durability] thread-sharing-through-domain
  # Sharing MUST delegate registered-recipient resolution, role validation and
  # current management authority to Threads.set_access with the current actor.
  # The server-held request key MUST survive errors and rotate only after success.
  def handle_event("thread_share", %{"access" => params}, socket) when is_map(params) do
    socket = assign(socket, share_form: to_form(params, as: :access))

    case Threads.set_access(
           %{
             thread_id: socket.assigns.selected.id,
             email: params["email"],
             role: params["role"],
             idempotency_key: socket.assigns.share_request_key
           },
           actor: socket.assigns.current_user
         ) do
      {:ok, _change} ->
        {:noreply,
         socket
         |> assign(
           share_form: to_form(%{"email" => "", "role" => "viewer"}, as: :access),
           share_request_key: Ash.UUID.generate(),
           share_error: nil,
           grant_cursor: nil
         )
         |> put_flash(:info, dgettext("agents", "Thread access updated."))
         |> refresh()}

      {:error, reason} ->
        {:noreply, socket |> assign(share_error: error_message(reason)) |> refresh()}
    end
  end

  def handle_event("grants_next", _params, socket),
    do: {:noreply, socket |> assign(grant_cursor: socket.assigns.grant_next) |> refresh()}

  def handle_event("grants_first", _params, socket),
    do: {:noreply, socket |> assign(grant_cursor: nil) |> refresh()}

  def handle_event(
        "activity_filter",
        %{"filter" => %{"status" => status} = filters},
        socket
      )
      when status in ["all", "pending", "provisioning", "ready", "failed", "deleting", "archived"] do
    time = Map.get(filters, "time", socket.assigns.activity_time_filter)
    owner = Map.get(filters, "owner", socket.assigns.activity_owner_filter)
    team = Map.get(filters, "team", socket.assigns.activity_team_filter)
    query = Map.get(filters, "query", socket.assigns.activity_query)

    if time in ["all", "today", "week", "month"] and owner in ["all", "mine", "shared"] and
         is_binary(team) and is_binary(query) do
      {:noreply,
       socket
       |> assign(
         activity_filter: status,
         activity_time_filter: time,
         activity_owner_filter: owner,
         activity_team_filter: team,
         activity_query: String.slice(query, 0, 200),
         thread_cursor: nil
       )
       |> refresh()}
    else
      {:noreply, socket}
    end
  end

  def handle_event(
        "generation_select",
        %{"generation" => %{"ordinal" => ordinal}},
        %{assigns: %{selected: %{id: thread_id}}} = socket
      )
      when is_binary(ordinal) do
    case parse_generation_ordinal(ordinal) do
      nil ->
        {:noreply, assign(socket, error: error_message(:not_found))}

      selected ->
        {:noreply,
         socket
         |> assign(selected_generation_ordinal: selected)
         |> push_patch(to: ~p"/threads/#{thread_id}?generation=#{selected}")}
    end
  end

  def handle_event(_event, _params, socket), do: {:noreply, socket}

  # @cc [owner:ghuntley,label:security;durability] composer-domain-actions
  # Commands MUST use the authenticated domain surface. Browser selection and
  # cached permissions MUST NOT authorize mutations. A refused command MUST keep
  # the user's draft and stable operation key for an unambiguous retry.
  @spec create_thread(socket(), map()) :: {:noreply, socket()}
  defp create_thread(socket, values) do
    with {:ok, spec} <- machine_spec(values),
         {:ok, thread} <-
           Threads.create_thread(
             %{
               objective: values["objective"],
               mode: values["mode"],
               collaboration_mode: values["collaboration_mode"] || "work",
               selected_skill_ids:
                 Enum.map(socket.assigns.selected_skills, &skill_value(&1, :id)),
               machine_spec: spec,
               idempotency_key: values["request_key"]
             },
             actor: socket.assigns.current_user
           ) do
      {:noreply, push_navigate(socket, to: ~p"/threads/#{thread.id}")}
    else
      {:error, reason} ->
        {:noreply,
         assign(socket, form: to_form(values, as: :thread), error: error_message(reason))}
    end
  end

  @spec submit_prompt(socket(), String.t(), atom() | nil) :: socket()
  defp submit_prompt(socket, text, mode) do
    params = %{
      thread_id: socket.assigns.selected.id,
      prompt: text,
      request_key: socket.assigns.prompt_request_key,
      selected_skill_ids: Enum.map(socket.assigns.selected_skills, &skill_value(&1, :id))
    }

    params = if mode, do: Map.put(params, :collaboration_mode, mode), else: params

    case Threads.submit_prompt(params, actor: socket.assigns.current_user) do
      {:ok, _} ->
        socket
        |> assign(
          prompt_request_key: Ash.UUID.generate(),
          error: nil,
          prompt_form: to_form(%{"text" => ""}, as: :prompt),
          selected_skills: []
        )
        |> push_event("thread-composer-clear", %{})
        |> put_flash(:info, dgettext("agents", "Prompt queued."))
        |> refresh()

      {:error, reason} ->
        assign(socket, error: error_message(reason))
    end
  end

  @spec run_command(socket(), ThreadCommands.command()) :: socket()
  defp run_command(%{assigns: %{live_action: :new}} = socket, mode) when mode in [:plan, :work] do
    values = Map.put(socket.assigns.form.params, "collaboration_mode", Atom.to_string(mode))
    assign(socket, form: to_form(values, as: :thread), error: nil)
  end

  defp run_command(socket, :help), do: assign(socket, thread_dialog: :help, error: nil)

  defp run_command(%{assigns: %{selected: nil}} = socket, _command),
    do: assign(socket, error: error_message(:operation_unavailable))

  defp run_command(socket, mode) when mode in [:plan, :work],
    do:
      control_action(
        socket,
        &Threads.set_collaboration_mode/2,
        %{collaboration_mode: mode},
        dgettext("agents", "Collaboration mode updated."),
        :none
      )

  defp run_command(socket, :compact),
    do:
      control_action(
        socket,
        &Threads.compact_context/2,
        %{},
        dgettext("agents", "Context compaction queued.")
      )

  defp run_command(socket, :context),
    do: socket |> assign(thread_dialog: :context, error: nil) |> refresh_dialog()

  defp run_command(socket, :skills),
    do: socket |> assign(thread_dialog: :skills, error: nil) |> refresh_skills()

  defp run_command(%{assigns: %{can_manage: true}} = socket, :share),
    do: socket |> assign(share_open: true, error: nil) |> refresh_grants()

  defp run_command(
         %{assigns: %{can_write: true, selected: %{status: :ready, machine_id: id}}} = socket,
         :terminal
       )
       when is_binary(id), do: push_navigate(socket, to: ~p"/machines/#{id}/terminals")

  defp run_command(
         %{assigns: %{editor_available: true, selected: %{machine_id: id}}} = socket,
         :code
       )
       when is_binary(id), do: redirect(socket, to: ~p"/machines/#{id}/code")

  defp run_command(socket, _command),
    do: assign(socket, error: error_message(:operation_unavailable))

  @type control_action :: (map(), keyword() -> {:ok, term()} | {:error, term()})
  @spec control_action(
          socket(),
          control_action(),
          map(),
          String.t(),
          :request_key | :idempotency_key | :none
        ) :: socket()
  defp control_action(socket, action, params, message, key_kind \\ :request_key)

  defp control_action(
         %{assigns: %{selected: nil}} = socket,
         _action,
         _params,
         _message,
         _key_kind
       ),
       do: assign(socket, error: error_message(:operation_unavailable))

  defp control_action(socket, action, params, message, key_kind) do
    params = Map.put(params, :thread_id, socket.assigns.selected.id)

    params =
      if key_kind == :none,
        do: params,
        else: Map.put(params, key_kind, socket.assigns.control_request_key)

    case action.(params, actor: socket.assigns.current_user) do
      {:ok, _} ->
        socket
        |> assign(error: nil, control_request_key: Ash.UUID.generate())
        |> put_flash(:info, message)
        |> refresh()

      {:error, reason} ->
        assign(socket, error: error_message(reason))
    end
  end

  @spec refresh_controls(socket()) :: socket()
  defp refresh_controls(%{assigns: %{selected: %{id: id}}} = socket) do
    case Threads.thread_controls(%{thread_id: id}, actor: socket.assigns.current_user) do
      {:ok, controls} ->
        assign(socket,
          controls_available: true,
          collaboration_mode: controls.collaboration_mode,
          work_busy: controls.busy,
          pending_question: controls.pending_question,
          question_answers:
            if(
              question_identity(controls.pending_question) ==
                question_identity(socket.assigns.pending_question),
              do: socket.assigns.question_answers,
              else: %{}
            ),
          latest_plan: controls.latest_plan
        )

      _ ->
        assign(socket,
          controls_available: false,
          work_busy: true,
          pending_question: nil,
          latest_plan: nil
        )
    end
  end

  defp refresh_controls(%{assigns: %{live_action: :new}} = socket) do
    assign(socket,
      controls_available: false,
      work_busy: false,
      pending_question: nil,
      latest_plan: nil,
      context_info: nil,
      context_available: false
    )
  end

  defp refresh_controls(socket),
    do:
      assign(socket,
        controls_available: false,
        work_busy: false,
        pending_question: nil,
        latest_plan: nil,
        selected_skills: [],
        context_info: nil,
        context_available: false,
        skills: [],
        managed_skills: [],
        skills_available: false,
        skill_query: nil
      )

  @spec refresh_dialog(socket()) :: socket()
  defp refresh_dialog(%{assigns: %{selected: %{id: id}, thread_dialog: :context}} = socket) do
    case Threads.context_info(%{thread_id: id}, actor: socket.assigns.current_user) do
      {:ok, info} -> assign(socket, context_info: info, context_available: true)
      _ -> assign(socket, context_info: nil, context_available: false)
    end
  end

  defp refresh_dialog(%{assigns: %{thread_dialog: :skills}} = socket), do: refresh_skills(socket)
  defp refresh_dialog(socket), do: socket

  @spec refresh_skills(socket()) :: socket()
  defp refresh_skills(%{assigns: %{selected: %{id: id}}} = socket) do
    case Threads.list_skills(%{thread_id: id, limit: 100}, actor: socket.assigns.current_user) do
      {:ok, page} ->
        assign(socket,
          skills: page.items,
          managed_skills: Map.get(page, :installations, []),
          skills_available: true
        )

      _ ->
        assign(socket, skills: [], managed_skills: [], skills_available: false)
    end
  end

  defp refresh_skills(socket),
    do: assign(socket, skills: [], managed_skills: [], skills_available: false)

  @spec skill_value(map(), atom(), term()) :: term()
  defp skill_value(skill, key, default \\ nil),
    do: Map.get(skill, key, Map.get(skill, Atom.to_string(key), default))

  @spec matching_skills([map()], String.t() | nil) :: [map()]
  defp matching_skills(skills, query) do
    if is_binary(query) do
      Enum.filter(
        skills,
        &(skill_value(&1, :enabled, true) and
            String.contains?(String.downcase(skill_value(&1, :name, "")), String.downcase(query)))
      )
      |> Enum.take(20)
    else
      []
    end
  end

  # @cc [owner:ghuntley,label:security] thread-refresh-known-read-denial
  # When a refresh learns that current thread read permission is absent, it MUST
  # clear selected content, its list entry, transcript and machine actions in that
  # same refresh, even if later permission reads observe a concurrent regrant.
  @spec refresh(socket()) :: socket()
  # @cc [owner:ghuntley,label:reliability;security] threads-refresh-fails-closed
  # A database or authorization failure during refresh MUST degrade the page to
  # its unavailable state instead of crashing the LiveView, and MUST clear the
  # selected thread, its events, write/manage controls and grants rather than
  # keep details or permissions from an earlier refresh.
  @spec refresh(socket()) :: socket()
  defp refresh(socket) do
    load(socket)
  rescue
    _ in [
      Ash.Error.Forbidden,
      Ash.Error.Invalid,
      Ash.Error.Unknown,
      DBConnection.ConnectionError,
      Postgrex.Error
    ] ->
      unavailable(socket)
  end

  @spec unavailable(socket()) :: socket()
  defp unavailable(socket) do
    socket
    |> assign(
      threads_empty: false,
      thread_page_empty: false,
      thread_matches_empty: false,
      threads_available: false,
      activity_empty: true,
      selected: nil,
      generations: [],
      selected_generation: nil,
      generation_current: false,
      can_write: false,
      can_manage: false,
      editor_available: false,
      events_empty: true,
      events_available: false,
      controls_available: false,
      work_busy: false,
      pending_question: nil,
      latest_plan: nil,
      detail_error: if(socket.assigns[:selected_id], do: :unavailable)
    )
    |> stream(:threads, [], reset: true)
    |> stream(:activity_threads, [], reset: true)
    |> stream(:events, [], reset: true)
    |> clear_grants()
  end

  @spec load(socket()) :: socket()
  defp load(socket) do
    actor = socket.assigns.current_user

    {all_threads, thread_next, threads_available} =
      list_threads(actor, socket.assigns[:thread_cursor])

    {selected, detail_error} = selected_thread(socket.assigns[:selected_id], all_threads, actor)

    permissions =
      if selected,
        do: Threads.Authorization.permissions(selected, actor),
        else: %{read: false, write: false, manage: false}

    {selected, detail_error, all_threads, permissions} =
      if selected && !permissions.read do
        {nil, :forbidden, Enum.reject(all_threads, &(&1.id == selected.id)),
         %{read: false, write: false, manage: false}}
      else
        {selected, detail_error, all_threads, permissions}
      end

    activity_threads =
      activity_threads(
        all_threads,
        socket.assigns[:activity_filter],
        socket.assigns[:activity_time_filter],
        socket.assigns[:activity_owner_filter],
        socket.assigns[:activity_team_filter],
        socket.assigns[:activity_query],
        actor.id,
        socket.assigns[:time_zone]
      )

    visible_threads =
      filter_threads(all_threads, socket.assigns.thread_query, socket.assigns.thread_filter)

    {generations, generations_available} =
      if selected, do: list_generations(selected, actor), else: {[], true}

    selected_generation =
      if selected,
        do:
          choose_generation(
            generations,
            selected,
            socket.assigns[:selected_generation_ordinal]
          ),
        else: nil

    detail_error =
      cond do
        detail_error ->
          detail_error

        selected && socket.assigns[:generation_query_error] ->
          socket.assigns.generation_query_error

        selected && generations_available && socket.assigns[:selected_generation_ordinal] &&
            is_nil(selected_generation) ->
          :not_found

        true ->
          nil
      end

    generation_current =
      not is_nil(selected) and not is_nil(selected_generation) and
        selected_generation.machine_key == selected.machine_key

    {events, events_available} =
      if selected && selected_generation &&
           (selected_generation.agent_thread_id ||
              (generation_current && selected.agent_thread_id)),
         do: events_for(selected, actor, selected_generation),
         else: {[], true}

    catalog = catalog(actor)

    socket
    |> assign(
      threads_empty: all_threads == [] and is_nil(socket.assigns[:thread_cursor]),
      thread_page_empty: all_threads == [] and not is_nil(socket.assigns[:thread_cursor]),
      thread_matches_empty: visible_threads == [],
      threads_available: threads_available,
      thread_next: thread_next,
      activity_empty: activity_threads == [],
      selected: selected,
      generations: generations,
      generations_available: generations_available,
      selected_generation: selected_generation,
      generation_current: generation_current,
      can_write: not is_nil(selected) and generation_current and permissions.write,
      can_manage: not is_nil(selected) and permissions.manage,
      editor_available: generation_current and thread_editor_available?(selected, actor),
      events_empty: events == [],
      events_available: events_available,
      catalog: catalog,
      detail_error: detail_error,
      activity_team_options: activity_team_options(all_threads)
    )
    |> stream(:threads, visible_threads, reset: true)
    |> stream(:activity_threads, activity_threads, reset: true)
    |> stream(:events, Enum.reverse(events), reset: true)
    |> maybe_seed_defaults(catalog)
    |> refresh_grants()
    |> refresh_controls()
    |> refresh_dialog()
  end

  # @cc [owner:ghuntley,label:security] thread-grant-refresh-fails-closed
  # Grant refresh MUST replace its bounded page and clear owner, grants and
  # pagination after lost management access or a failed authorized read. Failed
  # reads MUST NOT leave an editable sharing form based on stale grant details.
  @spec refresh_grants(socket()) :: socket()
  defp refresh_grants(%{assigns: %{can_manage: true, share_open: true}} = socket) do
    case Threads.list_grants(
           %{
             thread_id: socket.assigns.selected.id,
             limit: 50,
             after: socket.assigns.grant_cursor
           },
           actor: socket.assigns.current_user
         ) do
      {:ok, page} ->
        socket
        |> assign(
          grant_owner: page.owner,
          grant_next: page.next_cursor,
          grants_available: true,
          grants_empty: page.items == []
        )
        |> stream(:thread_grants, page.items, reset: true)

      _ ->
        clear_grants(socket)
    end
  end

  defp refresh_grants(socket), do: clear_grants(socket)

  @spec clear_grants(socket()) :: socket()
  defp clear_grants(socket) do
    socket
    |> assign(grant_owner: nil, grant_next: nil, grants_available: false, grants_empty: true)
    |> stream(:thread_grants, [], reset: true)
  end

  # @cc [owner:ghuntley,label:security] thread-editor-projected-eligibility
  # The thread editor link MUST use a fresh actor-authorized VM projection and
  # the shared editor eligibility check. A thread binding alone MUST NOT imply
  # editor permission; the editor launch route MUST retain its own authorization.
  @spec thread_editor_available?(thread() | nil, user()) :: boolean()
  defp thread_editor_available?(%{status: :ready, machine_id: machine_id}, actor)
       when is_binary(machine_id) do
    case Compute.get_vm(%{vm_id: machine_id}, actor: actor) do
      {:ok, vm} -> WorkspaceComponents.editor_control(vm) == :available
      _ -> false
    end
  end

  defp thread_editor_available?(_thread, _actor), do: false

  @spec list_threads(user(), String.t() | nil) :: {[thread()], String.t() | nil, boolean()}
  defp list_threads(actor, cursor) do
    case Threads.list_thread_page(%{limit: 50, after: cursor}, actor: actor) do
      {:ok, %{items: threads, next_cursor: next_cursor}} -> {threads, next_cursor, true}
      _ -> {[], nil, false}
    end
  end

  defp catalog(actor) do
    case Compute.catalog(%{}, actor: actor) do
      {:ok, %{images: images}} -> %{images: images}
      _ -> %{images: []}
    end
  end

  @spec selected_thread(String.t() | nil, [thread()], user()) :: {thread() | nil, atom() | nil}
  defp selected_thread(nil, _threads, _actor), do: {nil, nil}

  defp selected_thread(id, threads, actor) do
    case Enum.find(threads, &(&1.id == id)) do
      nil ->
        case Threads.get_thread(%{thread_id: id}, actor: actor) do
          {:ok, thread} -> {thread, nil}
          {:error, reason} -> {nil, Threads.error_reason(reason)}
          _ -> {nil, :unavailable}
        end

      thread ->
        {thread, nil}
    end
  end

  # @cc [owner:ghuntley,label:product] thread-list-filter-scope
  # Thread search and status filters MUST operate only on the authorized bounded
  # list already returned by the domain; filters MUST NOT grant detail authority.
  @spec filter_threads([thread()], String.t(), String.t()) :: [thread()]
  defp filter_threads(threads, query, status) do
    query = query |> String.trim() |> String.downcase()

    Enum.filter(threads, fn thread ->
      matches_status =
        case status do
          "active" -> thread.status != :archived
          "archived" -> thread.status == :archived
          "all" -> true
        end

      text = String.downcase((thread.title || "") <> " " <> thread.objective)
      matches_status and String.contains?(text, query)
    end)
  end

  # @cc [owner:ghuntley,label:product;security] activity-filter-scope
  # Activity status, time, owner, team and text filters MUST narrow only the
  # already authorized bounded page. Filtering MUST NOT query or reveal a
  # thread outside that page; selecting a row still performs a fresh read check.
  @spec activity_threads(
          [thread()],
          String.t(),
          String.t(),
          String.t(),
          String.t(),
          String.t(),
          String.t(),
          TimeZones.iana() | nil
        ) :: [thread()]
  defp activity_threads(threads, status, time, owner, team, query, actor_id, zone) do
    now = DateTime.utc_now()

    threads
    |> Enum.filter(fn thread ->
      status_matches = status == "all" or Atom.to_string(thread.status) == status
      time_matches = time_matches?(thread.updated_at, time, zone, now)
      owner_matches = owner_matches?(thread, owner, actor_id)
      team_matches = team == "all" or to_string(thread.team_id) == team
      query = String.downcase(String.trim(query))
      text = String.downcase((thread.title || "") <> " " <> thread.objective)
      query_matches = query == "" or String.contains?(text, query)
      status_matches and time_matches and owner_matches and team_matches and query_matches
    end)
    |> Enum.sort_by(
      &{DateTime.to_unix(&1.updated_at, :microsecond), &1.id},
      :desc
    )
  end

  # @cc [owner:ghuntley,label:product] activity-time-filter-viewer-days
  # The today/week/month filters MUST compare calendar days in the viewer's
  # zone: today is the viewer's current local date, week the last seven local
  # dates and month the last thirty, all ending today. A thread updated after
  # now MUST NOT match. No filter may compare raw UTC seconds.
  @spec time_matches?(DateTime.t(), String.t(), TimeZones.iana() | nil, DateTime.t()) ::
          boolean()
  defp time_matches?(_updated_at, "all", _zone, _now), do: true

  defp time_matches?(%DateTime{} = updated_at, filter, zone, now)
       when filter in ["today", "week", "month"] do
    today = TimeZones.local_date(now, zone)
    day = TimeZones.local_date(updated_at, zone)
    days = %{"today" => 0, "week" => 6, "month" => 29}

    Date.compare(day, today) != :gt and
      Date.diff(today, day) <= Map.fetch!(days, filter) and
      DateTime.compare(updated_at, now) != :gt
  end

  defp time_matches?(_, _, _, _), do: true

  @spec owner_matches?(thread(), String.t(), String.t()) :: boolean()
  defp owner_matches?(_thread, "all", _actor_id), do: true
  defp owner_matches?(%{creator_id: actor_id}, "mine", actor_id), do: true
  defp owner_matches?(%{creator_id: creator_id}, "shared", actor_id), do: creator_id != actor_id
  defp owner_matches?(_, _, _), do: false

  @spec activity_team_options([thread()]) :: [{String.t(), String.t()}]
  defp activity_team_options(threads) do
    teams =
      threads
      |> Enum.map(& &1.team_id)
      |> Enum.filter(&is_binary/1)
      |> Enum.uniq()
      |> Enum.sort()

    [
      {dgettext("agents", "All teams"), "all"}
      | Enum.map(teams, &{dgettext("agents", "Team %{team}", team: &1), &1})
    ]
  end

  @spec events_for(thread(), user(), Marshall.Threads.Generation.t() | nil) ::
          {[Marshall.Agents.Event.t()], boolean()}
  defp events_for(thread, actor, generation) do
    result =
      if generation && generation.machine_key != thread.machine_key,
        do: Threads.events(thread.id, actor, generation.ordinal, 100),
        else: Threads.events(thread.id, actor)

    case result do
      {:ok, events} -> {events, true}
      _ -> {[], false}
    end
  end

  @spec list_generations(thread(), user()) ::
          {[Marshall.Threads.Generation.t()], boolean()}
  defp list_generations(thread, actor) do
    case Threads.generations(thread.id, actor) do
      {:ok, generations} -> {generations, true}
      _ -> {[], false}
    end
  end

  @spec choose_generation([Marshall.Threads.Generation.t()], thread(), integer() | nil) ::
          Marshall.Threads.Generation.t() | nil
  defp choose_generation([], _thread, _requested), do: nil

  defp choose_generation(generations, thread, requested) do
    case requested do
      nil ->
        Enum.find(generations, &(&1.machine_key == thread.machine_key)) || List.first(generations)

      ordinal ->
        Enum.find(generations, &(&1.ordinal == ordinal))
    end
  end

  @spec generation_query_error(term()) :: :not_found | nil
  defp generation_query_error(nil), do: nil

  defp generation_query_error(value),
    do: if(parse_generation_ordinal(value), do: nil, else: :not_found)

  @spec parse_generation_ordinal(term()) :: pos_integer() | nil
  defp parse_generation_ordinal(value) when is_integer(value) and value >= 1, do: value

  defp parse_generation_ordinal(value) when is_binary(value) do
    case Integer.parse(value) do
      {ordinal, ""} when ordinal >= 1 -> ordinal
      _ -> nil
    end
  end

  defp parse_generation_ordinal(_), do: nil

  @spec generation_option(Marshall.Threads.Generation.t()) :: {String.t(), integer()}
  defp generation_option(generation) do
    status = Atom.to_string(generation.status)

    {dgettext("agents", "Generation %{value1} (%{value2})",
       value1: generation.ordinal,
       value2: status
     ), generation.ordinal}
  end

  @spec maybe_seed_defaults(socket(), map()) :: socket()
  defp maybe_seed_defaults(
         %{assigns: %{live_action: :new, thread_defaults_seeded: false}} = socket,
         %{images: images}
       )
       when is_list(images) and images != [] do
    values =
      socket.assigns.form.params
      |> Map.merge(MachineDefaults.for_user(socket.assigns.current_user, :thread, images))

    assign(socket,
      form: to_form(values, as: :thread),
      thread_defaults_seeded: true
    )
  end

  defp maybe_seed_defaults(socket, _catalog), do: socket

  defp default_form do
    %{
      "objective" => "",
      "mode" => "medium",
      "collaboration_mode" => "work",
      "profile" => "standard",
      "image_id" => "",
      "vcpu" => "2",
      "memory_mib" => "4096",
      "disk_gib" => "40",
      "team_id" => "",
      "request_key" => Ash.UUID.generate()
    }
  end

  defp machine_spec(values) do
    with {:ok, vcpu} <- parse_integer(values["vcpu"]),
         {:ok, memory} <- parse_integer(values["memory_mib"]),
         {:ok, disk} <- parse_integer(values["disk_gib"]),
         true <- is_binary(values["image_id"]) and values["image_id"] != "" do
      {:ok,
       %{
         architecture: :x86_64,
         image_id: values["image_id"],
         profile: values["profile"] || "standard",
         vcpu: vcpu,
         memory_bytes: memory * 1_048_576,
         disk_bytes: disk * 1_073_741_824,
         team_id: blank_to_nil(values["team_id"])
       }}
    else
      _ -> {:error, :invalid_machine_spec}
    end
  end

  @spec parse_integer(term()) :: {:ok, integer()} | :error
  defp parse_integer(value) when is_integer(value), do: {:ok, value}

  defp parse_integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {integer, ""} -> {:ok, integer}
      _ -> :error
    end
  end

  defp parse_integer(_), do: :error

  defp blank_to_nil(nil), do: nil
  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: value

  @spec error_messages() :: %{atom() => String.t()}
  defp error_messages do
    %{
      unknown_command:
        dgettext(
          "agents",
          "Unknown command. Open Commands to choose one, or start with a space to send literal text."
        ),
      command_arguments:
        dgettext("agents", "This command does not accept a task. Your draft has been kept."),
      busy:
        dgettext(
          "agents",
          "Wait for the current work or pending questions to finish before changing this setting."
        ),
      operation_unavailable:
        dgettext("agents", "This command needs a ready thread and current write access."),
      stale_plan:
        dgettext("agents", "The plan has changed. Review the latest proposal before continuing."),
      stale_proposal:
        dgettext("agents", "The plan has changed. Review the latest proposal before continuing."),
      already_implemented:
        dgettext("agents", "Implementation has already started for this plan."),
      thread_busy:
        dgettext(
          "agents",
          "Wait for the current work or pending questions to finish before changing this setting."
        ),
      stale_question: dgettext("agents", "These questions are no longer waiting for an answer."),
      already_answered: dgettext("agents", "These questions have already been answered."),
      invalid_answers:
        dgettext("agents", "Answer each question with a choice, your own answer, or both."),
      context_pending:
        dgettext("agents", "Workspace context is being collected. Try again shortly."),
      context_unavailable:
        dgettext(
          "agents",
          "Workspace context is unavailable. Reload it when the machine is ready."
        ),
      context_changed:
        dgettext(
          "agents",
          "Workspace files changed during collection. Reload context and try again."
        ),
      context_too_large:
        dgettext(
          "agents",
          "The required instructions and current message do not fit. Reduce them and try again."
        ),
      context_limit_exceeded:
        dgettext(
          "agents",
          "The current context exceeds the model allowance. Compact it or reduce the message."
        ),
      compaction_no_progress:
        dgettext(
          "agents",
          "Compaction could not reduce this context. Reduce required instructions or start a focused thread."
        ),
      nothing_to_compact: dgettext("agents", "There is no older context to compact yet."),
      machine_pinned: dgettext("agents", "Unpin this thread's machine before deleting it."),
      skill_failed:
        dgettext(
          "agents",
          "The skill operation failed. The previous installed revision remains available."
        ),
      skill_ambiguous:
        dgettext(
          "agents",
          "More than one skill has this name. Select its exact source from Skills."
        ),
      skill_unavailable:
        dgettext(
          "agents",
          "A selected skill is no longer available. Reload Skills and select its current source."
        ),
      thread_not_ready: dgettext("agents", "This thread is still provisioning."),
      invalid_machine_spec: dgettext("agents", "Choose a valid image and machine size."),
      insufficient_capacity:
        dgettext("agents", "There is not enough capacity for this machine right now."),
      reopen_unavailable: dgettext("agents", "This thread is not archived."),
      not_found: dgettext("agents", "This thread could not be found."),
      unavailable:
        dgettext("agents", "This thread is temporarily unavailable. Try again shortly."),
      forbidden: dgettext("agents", "You do not have access to this thread."),
      recipient_not_registered:
        dgettext("agents", "That email does not belong to a registered account."),
      owner_protected: dgettext("agents", "The thread owner's access cannot be changed."),
      idempotency_conflict:
        dgettext(
          "agents",
          "This request was already used for a different change. Reload this page and try again."
        ),
      sharing_not_allowed:
        dgettext("agents", "Sharing is not available for this thread's machine profile.")
    }
  end

  @spec error_message(term()) :: String.t()
  defp error_message(reason),
    do:
      Map.get(
        error_messages(),
        Threads.error_reason(reason),
        dgettext("agents", "The thread operation could not be completed.")
      )

  # @cc [owner:ghuntley,label:product] thread-conversation-presentation
  # Thread views MUST keep the objective and authorized transcript primary. Machine
  # settings MUST remain optional disclosure, and pending/failed/archived states
  # MUST explain the available next action without exposing provider diagnostics.
  # The terminal action MUST use the existing machine route, preserving that
  # route's current authorization and terminal session checks.

  # @cc [owner:ghuntley,label:product] thread-newest-first-reading-order
  # The ready-thread composer MUST precede its transcript in DOM order. Authorized
  # transcript events MUST be displayed newest first, with oldest events last; the
  # domain event sequence and machine-scoped conversation order MUST stay unchanged.
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
      active="threads"
    >
      <section
        id="threads"
        class="threads-surface"
        data-view={@live_action}
        phx-hook="ThreadComposer"
        data-thread-new={to_string(@live_action == :new)}
        data-thread-selected={to_string(not is_nil(@selected))}
        data-thread-write={to_string(@can_write)}
        data-thread-manage={to_string(@can_manage)}
        data-thread-ready={to_string(not is_nil(@selected) and @selected.status == :ready)}
        data-thread-busy={to_string(@work_busy)}
        data-thread-editor={to_string(@editor_available)}
      >
        <header class="threads-toolbar">
          <nav aria-label={dgettext("agents", "Thread views")} class="threads-tabs">
            <.link navigate={~p"/threads"} aria-current={@live_action == :index && "page"}>
              {dgettext("agents", "Threads")}
            </.link>
            <.link navigate={~p"/threads/activity"} aria-current={@live_action == :activity && "page"}>
              {dgettext("agents", "Activity")}
            </.link>
          </nav>
          <.link :if={@live_action != :new} navigate={~p"/threads/new"} class="console-button primary">
            {dgettext("agents", "New thread")} <.glyph name="plus" />
          </.link>
          <span :if={@live_action == :new} class="muted">{dgettext("agents", "New thread")}</span>
        </header>

        <%= if @live_action == :new do %>
          <div class="thread-start">
            <header class="thread-start-heading">
              <p class="thread-eyebrow">{dgettext("agents", "A space for your next idea")}</p>
              <h1>{dgettext("agents", "What are we working on?")}</h1>
              <p class="muted">
                {dgettext("agents", "Describe a task. Your agent gets a machine and gets to work.")}
              </p>
            </header>
            <.form
              for={@form}
              id="new-thread-form"
              phx-change="validate"
              phx-submit="create"
              class="thread-composer thread-new-composer"
            >
              <div class="thread-composer-input">
                <.input
                  field={@form[:objective]}
                  type="textarea"
                  label={dgettext("agents", "Objective")}
                  data-thread-input="true"
                  aria-controls="thread-command-options"
                  aria-expanded="false"
                  placeholder={dgettext("agents", "Build something, fix a bug, explore an idea…")}
                  rows="6"
                  required
                />
              </div>
              <.composer_suggestions
                skills={@skills}
                query={@skill_query}
                selected_skills={@selected_skills}
              />
              <div class="thread-compose-controls">
                <div class="thread-mode-control">
                  <.input
                    field={@form[:collaboration_mode]}
                    type="select"
                    label={dgettext("agents", "Mode")}
                    options={[
                      {dgettext("agents", "Work"), "work"},
                      {dgettext("agents", "Plan"), "plan"}
                    ]}
                  />
                </div>
                <div class="thread-mode-control">
                  <.input
                    field={@form[:mode]}
                    type="select"
                    label={dgettext("agents", "Reasoning")}
                    options={[
                      {dgettext("agents", "Low"), "low"},
                      {dgettext("agents", "Medium"), "medium"},
                      {dgettext("agents", "High"), "high"},
                      {dgettext("agents", "Ultra"), "ultra"}
                    ]}
                  />
                </div>
                <button type="button" data-thread-commands-open class="console-button ghost">{dgettext(
                  "agents",
                  "Commands"
                )}</button>
                <button
                  id="create-thread"
                  class="console-button primary"
                  type="submit"
                  phx-disable-with={dgettext("agents", "Starting…")}
                >
                  {dgettext("agents", "Create thread")} <.glyph name="arrow_up" />
                </button>
              </div>
              <details id="thread-machine-settings" class="thread-machine-settings">
                <summary>
                  {dgettext("agents", "Machine settings")}
                  <span class="muted">· {machine_summary(@form.params)}</span>
                </summary>
                <div class="thread-settings-fields">
                  <.input
                    field={@form[:profile]}
                    type="select"
                    label={dgettext("agents", "Machine profile")}
                    options={[
                      {dgettext("agents", "Standard"), "standard"},
                      {dgettext("agents", "Open source"), "oss"}
                    ]}
                  />
                  <.input
                    field={@form[:image_id]}
                    type="select"
                    label={dgettext("agents", "Image")}
                    options={Enum.map(@catalog.images, &{&1.name || &1.id, &1.id})}
                    required
                  />
                  <.input
                    field={@form[:team_id]}
                    label={dgettext("agents", "Team (optional)")}
                    placeholder={dgettext("agents", "Team ID")}
                  />
                  <.input
                    field={@form[:vcpu]}
                    type="number"
                    label={dgettext("agents", "CPU")}
                    min="1"
                    max="32"
                  />
                  <.input
                    field={@form[:memory_mib]}
                    type="number"
                    label={dgettext("agents", "Memory (MiB)")}
                    min="512"
                  />
                  <.input
                    field={@form[:disk_gib]}
                    type="number"
                    label={dgettext("agents", "Disk (GiB)")}
                    min="2"
                  />
                </div>
              </details>
              <p :if={@error} id="thread-form-error" class="thread-form-feedback error" role="alert">
                {@error}
              </p>
            </.form>
            <p class="thread-mode-hint muted">
              {dgettext(
                "agents",
                "%{value1} Reasoning stays with this thread. Switch between Plan and Work as needed.",
                value1: mode_hint(@form.params["mode"])
              )}
            </p>
            <div class="thread-start-notes">
              <p>
                <strong>{dgettext("agents", "One task. One thread.")}</strong><br /><span class="muted">{dgettext(
                  "agents",
                  "Return to the conversation whenever you need."
                )}</span>
              </p>
              <p>
                <strong>{dgettext("agents", "A machine of its own.")}</strong><br /><span class="muted">{dgettext(
                  "agents",
                  "Your agent's work runs in a dedicated environment."
                )}</span>
              </p>
            </div>
          </div>
        <% else %>
          <div class={[
            "threads-layout",
            @live_action == :show && "threads-layout-detail",
            @live_action == :activity && "threads-layout-activity"
          ]}>
            <nav
              id="thread-list"
              aria-label={dgettext("agents", "Threads")}
              class={[
                "thread-list",
                "threads-navigation",
                @live_action == :index && "threads-index",
                @live_action == :activity && "threads-activity-navigation"
              ]}
            >
              <header class="thread-list-heading">
                <h1 :if={@live_action == :index}>{dgettext("agents", "Your threads")}</h1>
                <h2 :if={@live_action != :index}>{dgettext("agents", "Recent threads")}</h2>
                <p :if={@live_action == :index} class="muted">
                  {dgettext("agents", "Pick up where you left off.")}
                </p>
              </header>
              <p
                :if={!@threads_available}
                id="thread-list-unavailable"
                role="alert"
                class="thread-notice"
              >
                {dgettext("agents", "Threads are temporarily unavailable. Try again shortly.")}
              </p>
              <div :if={@threads_available and @threads_empty} class="thread-empty">
                <h2>{dgettext("agents", "Good work starts with a thread.")}</h2>
                <p class="muted">
                  {dgettext("agents", "Give your agent a task. Follow the work here.")}
                </p>
                <.link navigate={~p"/threads/new"} class="console-button primary">{dgettext(
                  "agents",
                  "New thread"
                )}</.link>
              </div>
              <p
                :if={@threads_available and @thread_page_empty}
                id="thread-page-empty"
                class="thread-empty muted"
              >
                {dgettext("agents", "No older threads are available on this page.")}
              </p>
              <.form
                :if={@live_action == :index and !@threads_empty}
                for={to_form(%{"query" => @thread_query, "status" => @thread_filter}, as: :filter)}
                id="thread-index-filter"
                phx-change="thread_filter"
                class="thread-index-filter"
              >
                <.input
                  name="filter[query]"
                  id="thread-search"
                  value={@thread_query}
                  type="search"
                  label={dgettext("agents", "Search recent threads")}
                  hint={dgettext("agents", "Searches this page of threads.")}
                  placeholder={dgettext("agents", "Find a task…")}
                  phx-debounce="200"
                  maxlength="200"
                />
                <.input
                  name="filter[status]"
                  id="thread-status-filter"
                  value={@thread_filter}
                  type="select"
                  label={dgettext("agents", "Show")}
                  options={[
                    {dgettext("agents", "All threads"), "all"},
                    {dgettext("agents", "Active"), "active"},
                    {dgettext("agents", "Archived"), "archived"}
                  ]}
                />
              </.form>
              <p
                :if={
                  @live_action == :index and !@threads_empty and !@thread_page_empty and
                    @thread_matches_empty
                }
                id="thread-search-empty"
                class="thread-empty muted"
              >
                {dgettext("agents", "No recent threads match your search.")}
              </p>
              <div id="thread-list-items" phx-update="stream">
                <.link
                  :for={{dom_id, thread} <- @streams.threads}
                  id={dom_id}
                  navigate={~p"/threads/#{thread.id}"}
                  aria-current={if thread.id == (@selected && @selected.id), do: "page"}
                  class="thread-navigation-item"
                >
                  <span class="thread-navigation-title">{thread.title ||
                    dgettext("agents", "Untitled thread")}</span>
                  <span class="thread-navigation-meta">
                    <span class="status-label" data-state={thread.status}>{status_label(thread.status)}</span>
                    <span class="thread-navigation-mode">{thread.mode}</span>
                    <.timestamp at={thread.updated_at} zone={@time_zone} format={:day_month} />
                  </span>
                  <span
                    :if={@live_action == :index and thread.objective != thread.title}
                    class="thread-index-objective"
                  >{thread.objective}</span>
                </.link>
              </div>
              <div :if={@thread_next || @thread_cursor} class="row actions thread-pagination">
                <button
                  :if={@thread_cursor}
                  id="thread-page-first"
                  type="button"
                  class="console-button compact ghost"
                  phx-click="threads_first"
                >{dgettext("agents", "First page")}</button>
                <button
                  :if={@thread_next}
                  id="thread-page-next"
                  type="button"
                  class="console-button compact ghost"
                  phx-click="threads_next"
                >{dgettext("agents", "Next page")}</button>
              </div>
              <.link
                navigate={~p"/threads/activity"}
                class="thread-navigation-activity-link"
                aria-current={@live_action == :activity && "page"}
              >
                {dgettext("agents", "View activity")} <.glyph name="arrow_up_right" />
              </.link>
            </nav>

            <%= if @live_action == :activity do %>
              <div id="thread-activity" class="thread-activity">
                <header class="thread-activity-heading">
                  <div>
                    <h1>{dgettext("agents", "Activity")}</h1><p class="muted">
                      {dgettext("agents", "The latest state of your threads.")}
                    </p>
                  </div>
                  <.form
                    for={
                      to_form(
                        %{
                          "status" => @activity_filter,
                          "time" => @activity_time_filter,
                          "owner" => @activity_owner_filter,
                          "team" => @activity_team_filter,
                          "query" => @activity_query
                        },
                        as: :filter
                      )
                    }
                    id="thread-activity-filter"
                    phx-change="activity_filter"
                  >
                    <.input
                      name="filter[status]"
                      id="thread-activity-status-filter"
                      value={@activity_filter}
                      type="select"
                      label={dgettext("agents", "Status")}
                      options={[
                        {dgettext("agents", "All threads"), "all"},
                        {dgettext("agents", "Pending"), "pending"},
                        {dgettext("agents", "Provisioning"), "provisioning"},
                        {dgettext("agents", "Ready"), "ready"},
                        {dgettext("agents", "Failed"), "failed"},
                        {dgettext("agents", "Deleting"), "deleting"},
                        {dgettext("agents", "Archived"), "archived"}
                      ]}
                    />
                    <.input
                      name="filter[time]"
                      id="thread-activity-time-filter"
                      value={@activity_time_filter}
                      type="select"
                      label={dgettext("agents", "Updated")}
                      options={[
                        {dgettext("agents", "Any time"), "all"},
                        {dgettext("agents", "Today"), "today"},
                        {dgettext("agents", "Past 7 days"), "week"},
                        {dgettext("agents", "Past 30 days"), "month"}
                      ]}
                    />
                    <.input
                      name="filter[owner]"
                      id="thread-activity-owner-filter"
                      value={@activity_owner_filter}
                      type="select"
                      label={dgettext("agents", "Scope")}
                      options={[
                        {dgettext("agents", "All visible"), "all"},
                        {dgettext("agents", "Mine"), "mine"},
                        {dgettext("agents", "Shared with me"), "shared"}
                      ]}
                    />
                    <.input
                      name="filter[team]"
                      id="thread-activity-team-filter"
                      value={@activity_team_filter}
                      type="select"
                      label={dgettext("agents", "Team")}
                      options={@activity_team_options}
                    />
                    <.input
                      name="filter[query]"
                      id="thread-activity-query"
                      value={@activity_query}
                      type="search"
                      label={dgettext("agents", "Search")}
                      placeholder={dgettext("agents", "Find a task…")}
                      phx-debounce="200"
                      maxlength="200"
                    />
                  </.form>
                </header>
                <p
                  :if={!@threads_available}
                  id="thread-list-unavailable"
                  class="thread-notice"
                  role="alert"
                >
                  {dgettext("agents", "Threads are temporarily unavailable. Try again shortly.")}
                </p>
                <p
                  :if={@threads_available and @activity_empty}
                  id="thread-activity-empty"
                  class="thread-empty muted"
                >
                  {dgettext("agents", "No activity matches this filter.")}
                </p>
                <div id="thread-activity-items" phx-update="stream">
                  <.link
                    :for={{dom_id, thread} <- @streams.activity_threads}
                    id={dom_id}
                    navigate={~p"/threads/#{thread.id}"}
                    class="thread-activity-item"
                  >
                    <time
                      datetime={DateTime.to_iso8601(thread.updated_at)}
                      title={TimeZones.utc_text(thread.updated_at)}
                      class="thread-activity-time"
                    >
                      <span>{TimeZones.format(thread.updated_at, @time_zone, :day_month)}</span>
                      <span>{TimeZones.format(thread.updated_at, @time_zone, :time)}</span>
                    </time>
                    <span class="thread-activity-description">
                      <strong>{thread.title || dgettext("agents", "Untitled thread")}</strong>
                      <span class="muted">{status_description(thread.status)}</span>
                    </span>
                    <span class="status-label" data-state={thread.status}>{status_label(thread.status)}</span>
                  </.link>
                </div>
              </div>
            <% else %>
              <div id="thread-workspace" class="thread-workspace">
                <p :if={@error} id="thread-operation-error" class="thread-notice error" role="alert">
                  {@error}
                </p>
                <%= if @detail_error do %>
                  <%= case @detail_error do %>
                    <% :forbidden -> %>
                      <div id="thread-forbidden" class="thread-empty" role="alert">
                        <h2>{dgettext("agents", "Thread unavailable")}</h2><p class="muted">
                          {dgettext("agents", "You do not have access to this thread.")}
                        </p><.link navigate={~p"/threads"}>{dgettext("agents", "Back to threads")}</.link>
                      </div>
                    <% :not_found -> %>
                      <div id="thread-not-found" class="thread-empty" role="alert">
                        <h2>{dgettext("agents", "Thread not found")}</h2><p class="muted">
                          {dgettext(
                            "agents",
                            "This thread may have been deleted or the link is invalid."
                          )}
                        </p><.link navigate={~p"/threads"}>{dgettext("agents", "Back to threads")}</.link>
                      </div>
                    <% _ -> %>
                      <div id="thread-unavailable" class="thread-empty" role="alert">
                        <h2>{dgettext("agents", "Thread temporarily unavailable")}</h2><p class="muted">
                          {dgettext("agents", "Try again shortly.")}
                        </p><.link navigate={~p"/threads"}>{dgettext("agents", "Back to threads")}</.link>
                      </div>
                  <% end %>
                <% else %>
                  <%= if @selected do %>
                    <header class="thread-detail-heading">
                      <div class="thread-detail-title">
                        <h1>{@selected.title || dgettext("agents", "Untitled thread")}</h1>
                        <p class="muted">
                          <span class="status-label" data-state={@selected.status}>{status_label(
                            @selected.status
                          )}</span><span>{dgettext("agents", "· %{value1} reasoning · %{value2}",
                            value1: @selected.mode,
                            value2: collaboration_label(@collaboration_mode)
                          )}</span>
                        </p>
                      </div>
                      <div class="thread-detail-actions">
                        <button
                          :if={!@can_write or @selected.status != :ready}
                          type="button"
                          data-thread-commands-open
                          class="console-button ghost"
                        >{dgettext("agents", "Commands")}</button>
                        <button
                          :if={@can_manage}
                          id="thread-share-toggle"
                          type="button"
                          phx-click="toggle_share"
                          class="console-button ghost"
                          aria-expanded={to_string(@share_open)}
                          aria-controls="thread-sharing"
                        >{dgettext("agents", "Share")}</button>
                        <div
                          :if={@can_write and @selected.status == :ready and @selected.machine_id}
                          id="thread-terminal"
                        >
                          <.link
                            navigate={~p"/machines/#{@selected.machine_id}/terminals"}
                            class="console-button ghost"
                          >{dgettext("agents", "Open terminal")} <.glyph name="arrow_up_right" /></.link>
                        </div>
                        <.link
                          :if={@editor_available}
                          id="thread-vscode"
                          href={~p"/machines/#{@selected.machine_id}/code"}
                          target="_blank"
                          rel="noopener noreferrer"
                          class="console-button ghost"
                        >{dgettext("agents", "Open VS Code")} <.glyph name="arrow_up_right" /></.link>
                        <.link
                          :if={@selected.machine_id}
                          id="thread-message-board"
                          navigate={
                            ~p"/message-board?profile=standard&vm_id=#{@selected.machine_id}&thread_id=#{@selected.id}"
                          }
                          class="console-button ghost"
                        >{dgettext("agents", "Message board")}</.link>
                        <details
                          :if={
                            @can_manage and
                              @selected.status in [:pending, :provisioning, :ready, :failed]
                          }
                          class="thread-actions-menu"
                        >
                          <summary aria-label={dgettext("agents", "Thread actions")}>
                            {dgettext("agents", "Actions")}
                          </summary>
                          <div class="thread-actions-options">
                            <button phx-click="archive" class="console-button ghost">{dgettext(
                              "agents",
                              "Archive"
                            )}</button>
                            <button phx-click="delete" class="console-button ghost">{dgettext(
                              "agents",
                              "Delete"
                            )}</button>
                          </div>
                        </details>
                        <button
                          :if={@can_manage and @selected.status == :archived}
                          phx-click="reopen"
                          class="console-button primary"
                        >{dgettext("agents", "Reopen")}</button>
                      </div>
                    </header>
                    <section
                      :if={@can_manage and @share_open}
                      id="thread-sharing"
                      class="thread-sharing"
                      aria-labelledby="thread-sharing-heading"
                    >
                      <header>
                        <h2 id="thread-sharing-heading">{dgettext("agents", "Share this thread")}</h2><p class="muted">
                          {dgettext(
                            "agents",
                            "Thread access also applies to its machine. Separate machine grants and team access are managed independently."
                          )}
                        </p>
                      </header>
                      <p :if={!@grants_available} id="thread-grants-unavailable" role="alert">
                        {dgettext(
                          "agents",
                          "Access details are temporarily unavailable. Close sharing and try again shortly."
                        )}
                      </p>
                      <%= if @grants_available do %>
                        <div :if={@grant_owner} id="thread-grant-owner" class="thread-grant-row">
                          <.person
                            id="thread-grant-owner-person"
                            email={@grant_owner.email}
                            time_zone={@grant_owner.time_zone}
                            viewer_zone={@time_zone}
                            now={@now}
                          /><span class="muted">{dgettext("agents", "Owner · cannot be changed")}</span>
                        </div>
                        <div id="thread-grant-items" phx-update="stream">
                          <div
                            :for={{dom_id, grant} <- @streams.thread_grants}
                            id={dom_id}
                            class="thread-grant-row"
                          >
                            <.person
                              id={"#{dom_id}-person"}
                              email={grant.email}
                              time_zone={grant.time_zone}
                              viewer_zone={@time_zone}
                              now={@now}
                            />
                            <span class="status-label" data-role={grant.role}>{role_label(grant.role)}</span>
                            <button
                              type="button"
                              class="console-button compact ghost"
                              phx-click="edit_access"
                              phx-value-email={grant.email}
                              phx-value-role={grant.role}
                            >{dgettext("agents", "Change")}</button>
                          </div>
                        </div>
                        <p :if={@grants_empty} class="muted">
                          {dgettext("agents", "No individual thread grants yet.")}
                        </p>
                        <div :if={@grant_cursor || @grant_next} class="row actions">
                          <button
                            :if={@grant_cursor}
                            type="button"
                            class="console-button compact ghost"
                            phx-click="grants_first"
                          >{dgettext("agents", "First page")}</button>
                          <button
                            :if={@grant_next}
                            type="button"
                            class="console-button compact ghost"
                            phx-click="grants_next"
                          >{dgettext("agents", "Next page")}</button>
                        </div>
                        <.form
                          for={@share_form}
                          id="thread-access-form"
                          phx-change="validate_access"
                          phx-submit="thread_share"
                          class="thread-access-form"
                        >
                          <p class="muted">
                            {dgettext(
                              "agents",
                              "Use an existing account's email to grant, change or revoke a thread role."
                            )}
                          </p>
                          <div class="thread-access-fields">
                            <.input
                              field={@share_form[:email]}
                              type="email"
                              label={dgettext("agents", "Registered email")}
                              required
                            />
                            <.input
                              field={@share_form[:role]}
                              type="select"
                              label={dgettext("agents", "Role")}
                              options={[
                                {dgettext("agents", "Viewer"), "viewer"},
                                {dgettext("agents", "Operator"), "operator"},
                                {dgettext("agents", "Manager"), "manager"},
                                {dgettext("agents", "Revoke thread grant"), "revoked"}
                              ]}
                            />
                            <button
                              class="console-button primary"
                              type="submit"
                              phx-disable-with={dgettext("agents", "Saving…")}
                            >{dgettext("agents", "Save access")}</button>
                          </div>
                          <p class="muted thread-access-hint">
                            {dgettext(
                              "agents",
                              "Viewers read. Operators send prompts. Managers also share and manage the thread."
                            )}
                          </p>
                          <p :if={@share_error} id="thread-share-error" class="error" role="alert">
                            {@share_error}
                          </p>
                        </.form>
                      <% end %>
                    </section>
                    <section
                      :if={@generations_available and length(@generations) > 1}
                      id="thread-generations"
                      class="thread-generations"
                      aria-labelledby="thread-generations-heading"
                    >
                      <header>
                        <h2 id="thread-generations-heading">
                          {dgettext("agents", "Machine generations")}
                        </h2>
                        <p class="muted">
                          {dgettext(
                            "agents",
                            "Reopened machines keep their earlier transcripts. Select one to read it."
                          )}
                        </p>
                      </header>
                      <.form
                        for={to_form(%{"ordinal" => @selected_generation.ordinal}, as: :generation)}
                        id="thread-generation-selector"
                        phx-change="generation_select"
                      >
                        <.input
                          field={
                            to_form(%{"ordinal" => @selected_generation.ordinal}, as: :generation)[
                              :ordinal
                            ]
                          }
                          type="select"
                          label={dgettext("agents", "Transcript")}
                          options={Enum.map(@generations, &generation_option/1)}
                        />
                      </.form>
                    </section>
                    <div class="thread-conversation">
                      <p
                        :if={@selected.status == :ready and !@can_write}
                        id="thread-read-only"
                        class="thread-notice muted"
                      >
                        {dgettext("agents", "You have read-only access to this thread.")}
                      </p>
                      <div
                        :if={@selected.status in [:pending, :provisioning]}
                        id="thread-provisioning"
                        class="thread-notice"
                        role="status"
                      >
                        <strong>{dgettext("agents", "Preparing your workspace")}</strong>
                        <p class="muted">
                          {dgettext(
                            "agents",
                            "Your machine is starting. The agent will begin with your objective as soon as it is ready."
                          )}
                        </p>
                      </div>
                      <div :if={@selected.status == :failed} class="thread-notice thread-recovery">
                        <div>
                          <strong id="thread-provision-error">{dgettext(
                            "agents",
                            "Provisioning needs attention."
                          )}</strong><p class="muted">
                            {dgettext(
                              "agents",
                              "Your objective is saved. Retry to prepare the workspace again."
                            )}
                          </p>
                        </div>
                        <button :if={@can_manage} phx-click="retry" class="console-button primary">{dgettext(
                          "agents",
                          "Retry"
                        )}</button>
                      </div>
                      <p
                        :if={@selected.status == :deleting}
                        id="thread-deleting"
                        class="thread-notice muted"
                      >
                        {dgettext(
                          "agents",
                          "Archiving is in progress. Waiting for the machine to be deleted."
                        )}
                      </p>
                      <.form
                        :if={@can_write and @selected.status == :ready}
                        for={@prompt_form}
                        id="thread-prompt-form"
                        phx-change="validate_prompt"
                        phx-submit="prompt"
                        class="thread-composer thread-reply-composer"
                      >
                        <div class="thread-composer-input">
                          <.input
                            field={@prompt_form[:text]}
                            data-thread-input="true"
                            aria-controls="thread-command-options"
                            aria-expanded="false"
                            type="textarea"
                            aria-label={dgettext("agents", "Message")}
                            placeholder={dgettext("agents", "Continue the work…")}
                            rows="2"
                            required
                          />
                        </div>
                        <.composer_suggestions
                          skills={@skills}
                          query={@skill_query}
                          selected_skills={@selected_skills}
                        />
                        <input type="hidden" name="prompt[key]" value={@prompt_request_key} />
                        <div class="thread-compose-controls">
                          <div
                            class="thread-collaboration-options"
                            aria-label={dgettext("agents", "Collaboration mode")}
                          >
                            <button
                              :for={mode <- [:work, :plan]}
                              type="button"
                              phx-click="thread_command"
                              phx-value-command={mode}
                              class={[
                                "console-button compact",
                                @collaboration_mode == mode && "primary"
                              ]}
                              aria-pressed={to_string(@collaboration_mode == mode)}
                              disabled={@work_busy or !@controls_available}
                            >{collaboration_label(mode)}</button>
                          </div>
                          <span class="muted">{dgettext("agents", "%{value1} reasoning",
                            value1: @selected.mode
                          )}</span>
                          <button type="button" data-thread-commands-open class="console-button ghost">{dgettext(
                            "agents",
                            "Commands"
                          )}</button>
                          <button
                            class="console-button primary"
                            type="submit"
                            phx-disable-with={dgettext("agents", "Sending…")}
                            disabled={not is_nil(@pending_question) or !@controls_available}
                          >{dgettext("agents", "Send")} <.glyph name="arrow_up" /></button>
                        </div>
                      </.form>
                      <section
                        :if={@pending_question}
                        id="thread-pending-questions"
                        class="thread-question-card"
                        aria-labelledby="thread-questions-heading"
                      >
                        <h2 id="thread-questions-heading">
                          {dgettext("agents", "Your input is needed")}
                        </h2>
                        <p class="muted">
                          {dgettext("agents", "Answer these questions to continue the plan.")}
                        </p>
                        <.form
                          :if={@can_write}
                          for={@question_form}
                          id="thread-question-form"
                          phx-submit="answer_questions"
                          phx-change="validate_questions"
                        >
                          <input type="hidden" name="question_id" value={@pending_question.id} />
                          <fieldset :for={question <- @pending_question.questions}>
                            <legend>{question["header"]}: {question["question"]}</legend>
                            <label
                              :for={{option, index} <- Enum.with_index(question["options"])}
                              class="thread-answer-option"
                            >
                              <input
                                type="radio"
                                name={"answers[#{question["id"]}][selected]"}
                                value={option["label"]}
                                checked={
                                  get_in(@question_answers, [question["id"], "selected"]) ==
                                    option["label"]
                                }
                                id={"thread-answer-#{question["id"]}-#{index}"}
                              />
                              <span><strong>{option["label"]}</strong><br /><span class="muted">{option[
                                "description"
                              ]}</span></span>
                            </label>
                            <.input
                              type="textarea"
                              name={"answers[#{question["id"]}][text]"}
                              id={"thread-answer-#{question["id"]}-text"}
                              value={get_in(@question_answers, [question["id"], "text"]) || ""}
                              label={dgettext("agents", "Your answer or additional detail")}
                              rows="2"
                            />
                          </fieldset>
                          <button
                            type="submit"
                            class="console-button primary"
                            phx-disable-with={dgettext("agents", "Submitting…")}
                          >{dgettext("agents", "Submit answers")}</button>
                        </.form>
                        <div :if={!@can_write} class="stack">
                          <p :for={question <- @pending_question.questions}>{question["question"]}</p>
                          <p class="muted">
                            {dgettext("agents", "An operator can answer these questions.")}
                          </p>
                        </div>
                      </section>
                      <section
                        :if={@latest_plan}
                        id="thread-plan-card"
                        class="thread-plan-card"
                        aria-labelledby="thread-plan-heading"
                      >
                        <header class="row actions">
                          <h2 id="thread-plan-heading">{dgettext("agents", "Proposed plan")}</h2><span
                            :if={@latest_plan.implementing_turn_id}
                            class="status-label"
                          >{dgettext("agents", "Implementation started")}</span>
                        </header>
                        <pre>{@latest_plan.text}</pre>
                        <div
                          :if={@can_write and is_nil(@latest_plan.implementing_turn_id)}
                          class="row actions"
                        >
                          <button
                            id="thread-implement-plan"
                            type="button"
                            phx-click="implement_plan"
                            phx-value-plan_id={@latest_plan.id}
                            class="console-button primary"
                            disabled={@work_busy or !@controls_available}
                          >{dgettext("agents", "Implement plan")}</button>
                          <button
                            id="thread-revise-plan"
                            type="button"
                            phx-click="revise_plan"
                            phx-value-plan_id={@latest_plan.id}
                            class="console-button ghost"
                            disabled={@work_busy or !@controls_available}
                          >{dgettext("agents", "Revise")}</button>
                        </div>
                      </section>
                      <div id="thread-events" class="thread-events">
                        <p
                          :if={@selected.status == :archived}
                          id="thread-archived"
                          class="thread-notice muted"
                        >
                          {dgettext(
                            "agents",
                            "Archived thread. The transcript is read-only. Reopen to continue on a new machine."
                          )}
                        </p>
                        <p
                          :if={!@events_available}
                          id="thread-events-unavailable"
                          class="thread-notice"
                          role="alert"
                        >
                          {dgettext(
                            "agents",
                            "The transcript is temporarily unavailable. Try again shortly."
                          )}
                        </p>
                        <article
                          :if={@events_available and @events_empty}
                          class="thread-message"
                          data-kind="prompt"
                        >
                          <p class="thread-message-role">{dgettext("agents", "Objective")}</p>
                          <pre>{@selected.objective}</pre>
                        </article>
                        <p
                          :if={@events_available and @events_empty and @selected.status == :ready}
                          class="muted"
                        >
                          {dgettext("agents", "Waiting for the agent's first update.")}
                        </p>
                        <div id="thread-transcript" phx-update="stream">
                          <article
                            :for={{dom_id, event} <- @streams.events}
                            id={dom_id}
                            class={[
                              "thread-message",
                              event.kind not in [:prompt, :assistant] && "thread-system-event"
                            ]}
                            data-kind={event.kind}
                          >
                            <%= if event.kind in [:prompt, :assistant] do %>
                              <p class="thread-message-role">{event_role(event.kind)}</p>
                              <pre>{event_text(event)}</pre>
                            <% else %>
                              <p class="thread-event-label">{event_text(event)}</p>
                            <% end %>
                          </article>
                        </div>
                      </div>
                    </div>
                  <% end %>
                <% end %>
              </div>
            <% end %>
          </div>
        <% end %>
        <dialog
          id="thread-command-palette"
          class="thread-dialog"
          aria-labelledby="thread-command-heading"
          phx-update="ignore"
        >
          <header class="thread-dialog-heading">
            <h2 id="thread-command-heading">{dgettext("agents", "Commands")}</h2><button
              type="button"
              data-thread-commands-close
              class="console-button compact ghost"
            >{dgettext("agents", "Close")}</button>
          </header>
          <.input
            id="thread-command-search"
            type="search"
            name="command_search"
            value=""
            label={dgettext("agents", "Find a command")}
            autocomplete="off"
            role="combobox"
            aria-autocomplete="list"
            aria-expanded="false"
            aria-controls="thread-command-options"
          />
          <div
            id="thread-command-options"
            role="listbox"
            aria-label={dgettext("agents", "Commands")}
            class="thread-command-list"
          >
            <button
              :for={{command, label, description} <- ThreadCommands.all()}
              id={"thread-command-#{command}"}
              type="button"
              data-thread-command={command}
              role="option"
              aria-selected="false"
            ><span><strong>/{command}</strong> · {label}</span><span class="muted">{description}</span></button>
          </div>
          <p class="muted">{dgettext("agents", "↑ ↓ choose · Enter run · Escape close")}</p>
        </dialog>
        <dialog
          :if={@thread_dialog}
          id="thread-detail-dialog"
          class="thread-dialog thread-detail-dialog"
          data-thread-dialog="true"
          aria-labelledby="thread-dialog-heading"
        >
          <header class="thread-dialog-heading">
            <h2 id="thread-dialog-heading">{dialog_title(@thread_dialog)}</h2><button
              id="thread-dialog-close"
              type="button"
              phx-click="close_thread_dialog"
              class="console-button compact ghost"
            >{dgettext("agents", "Close")}</button>
          </header>
          <p :if={@error} role="alert">{@error}</p>
          <%= if @thread_dialog == :help do %>
            <p>
              {dgettext(
                "agents",
                "Use Commands or press Ctrl/Cmd+K while writing. Start a message with / to find a command; use Tab to complete it."
              )}
            </p>
            <dl class="thread-command-help">
              <%= for {command, label, description} <- ThreadCommands.all() do %>
                <dt><strong>/{command}</strong> · {label}</dt><dd>{description}</dd>
              <% end %>
            </dl>
            <p>
              <code>/plan task</code>
              {dgettext("agents", "and")} <code>/work task</code>
              {dgettext(
                "agents",
                "choose a mode and submit the task together. Choosing a mode on a new thread does not create a machine."
              )}
            </p>
            <p>
              {dgettext(
                "agents",
                "Start with a space to send slash-looking text literally. Type $ to choose a skill by its exact source."
              )}
            </p>
          <% end %>
          <%= if @thread_dialog == :context do %>
            <p :if={!@context_available} role="status">
              {dgettext(
                "agents",
                "Context details are unavailable. The thread may still be preparing its workspace."
              )}
            </p>
            <%= if @context_available do %>
              <dl class="kv">
                <dt>{dgettext("agents", "Status")}</dt><dd>
                  {context_status_label(skill_value(@context_info, :status, nil))}
                </dd><dt>
                  {dgettext("agents", "Working directory")}
                </dt><dd class="break">
                  {skill_value(
                    @context_info,
                    :working_directory,
                    dgettext("agents", "Not collected yet")
                  )}
                </dd><dt>{dgettext("agents", "Input tokens")}</dt><dd>
                  {context_usage(@context_info, :input_tokens)}
                </dd><dt>
                  {dgettext("agents", "Token allowance")}
                </dt><dd>{context_usage(@context_info, :token_limit)}</dd><dt>
                  {dgettext("agents", "Context bytes")}
                </dt><dd>
                  {context_usage(@context_info, :bytes)}
                </dd>
              </dl>
              <h3>{dgettext("agents", "Loaded sources")}</h3>
              <p :if={skill_value(@context_info, :sources, []) == []} class="muted">
                {dgettext("agents", "No instruction sources collected yet.")}
              </p>
              <ul class="thread-context-sources">
                <li :for={source <- skill_value(@context_info, :sources, [])}>
                  <strong>{skill_value(source, :kind, "Instructions")}</strong><br /><span class="break">{skill_value(
                    source,
                    :path,
                    dgettext("agents", "Workspace source")
                  )}</span>
                </li>
              </ul>
              <p :for={warning <- skill_value(@context_info, :warnings, [])} class="thread-notice">
                {context_warning(warning)}
              </p>
            <% end %>
            <div :if={@can_write} class="row actions">
              <button
                type="button"
                phx-click="reload_context"
                class="console-button primary"
                disabled={@work_busy}
              >{dgettext("agents", "Reload context")}</button><button
                type="button"
                phx-click="thread_command"
                phx-value-command="compact"
                class="console-button ghost"
                disabled={@work_busy}
              >{dgettext("agents", "Compact context")}</button>
            </div>
          <% end %>
          <%= if @thread_dialog == :skills do %>
            <p>
              {dgettext(
                "agents",
                "Skills add reusable instructions to a task. Choose the source you intend to use."
              )}
            </p>
            <p :if={!@skills_available} role="status">
              {dgettext(
                "agents",
                "Skills are unavailable until the workspace context has been collected."
              )}
            </p>
            <p :if={@skills_available and @skills == []} class="muted">
              {dgettext("agents", "No skills were discovered in this workspace.")}
            </p>
            <div id="thread-skill-catalog" class="stack">
              <article
                :for={skill <- @skills}
                class="thread-skill-item"
                data-skill-id={skill_value(skill, :id)}
              >
                <header>
                  <strong>{skill_value(skill, :name, "Skill")}</strong><span
                    :if={!skill_value(skill, :enabled, true)}
                    class="status-label"
                  >{dgettext("agents", "Disabled")}</span>
                </header>
                <p>{skill_value(skill, :description, "")}</p><p class="muted break">
                  {skill_value(
                    skill,
                    :path,
                    skill_value(skill, :scope, dgettext("agents", "Managed skill"))
                  )}
                </p>
                <button
                  :if={@can_write and skill_value(skill, :enabled, true)}
                  type="button"
                  phx-click="select_skill"
                  phx-value-id={skill_value(skill, :id)}
                  class="console-button compact ghost"
                >{dgettext("agents", "Use this skill")}</button>
              </article>
            </div>
            <section :if={@can_manage} class="thread-skill-management">
              <h3>{dgettext("agents", "Managed installations")}</h3>
              <article :for={skill <- @managed_skills} class="thread-skill-item">
                <strong>{skill_value(skill, :name, "Skill")}</strong><span class="status-label">{skill_value(
                  skill,
                  :status,
                  "pending"
                )}</span>
                <p class="muted break">{skill_value(skill, :source_url, "")}</p><p class="muted break">
                  {dgettext("agents", "Commit: %{value1}",
                    value1: skill_value(skill, :commit, "Pending")
                  )}
                </p>
                <.form
                  for={to_form(%{"revision" => ""}, as: :update)}
                  id={"thread-update-skill-#{skill_value(skill, :id)}"}
                  phx-submit="update_skill"
                  class="thread-skill-update"
                >
                  <input type="hidden" name="update[installation_id]" value={skill_value(skill, :id)} />
                  <.input
                    name="update[revision]"
                    id={"thread-skill-revision-#{skill_value(skill, :id)}"}
                    value=""
                    label={dgettext("agents", "Update revision (optional)")}
                    placeholder={dgettext("agents", "Branch, tag or commit")}
                  />
                  <button
                    type="submit"
                    class="console-button ghost"
                    phx-disable-with={dgettext("agents", "Updating…")}
                  >{dgettext("agents", "Update")}</button>
                </.form>
                <div class="row actions">
                  <button
                    type="button"
                    class="console-button compact ghost"
                    phx-click="set_skill_enabled"
                    phx-value-id={skill_value(skill, :id)}
                    phx-value-enabled={to_string(!skill_value(skill, :enabled, true))}
                  >{if skill_value(skill, :enabled, true),
                    do: dgettext("agents", "Disable"),
                    else: dgettext("agents", "Enable")}</button>
                  <button
                    type="button"
                    class="console-button compact ghost"
                    phx-click="remove_skill"
                    phx-value-id={skill_value(skill, :id)}
                  >{dgettext("agents", "Remove")}</button>
                </div>
              </article>
              <.form
                for={@skill_form}
                id="thread-skill-install"
                phx-change="validate_skill"
                phx-submit="install_skill"
                class="stack"
              >
                <h3>{dgettext("agents", "Install a skill")}</h3><p class="muted">
                  {dgettext(
                    "agents",
                    "Use a public GitHub, GitLab, Codeberg or Bitbucket repository."
                  )}
                </p>
                <.input
                  field={@skill_form[:url]}
                  type="url"
                  label={dgettext("agents", "Repository URL")}
                  placeholder="https://github.com/owner/repository"
                  required
                />
                <.input
                  field={@skill_form[:revision]}
                  label={dgettext("agents", "Revision (optional)")}
                  placeholder={dgettext("agents", "Branch, tag or commit")}
                />
                <.input
                  field={@skill_form[:subdirectory]}
                  label={dgettext("agents", "Skill directory")}
                  required
                />
                <button
                  type="submit"
                  class="console-button primary"
                  phx-disable-with={dgettext("agents", "Installing…")}
                >{dgettext("agents", "Install skill")}</button>
              </.form>
            </section>
          <% end %>
        </dialog>
      </section>
    </Layouts.app>
    """
  end

  attr :skills, :list, required: true
  attr :query, :string, default: nil
  attr :selected_skills, :list, required: true

  @spec composer_suggestions(map()) :: Phoenix.LiveView.Rendered.t()
  defp composer_suggestions(assigns) do
    ~H"""
    <div
      id="thread-slash-options"
      role="listbox"
      aria-label={dgettext("agents", "Command suggestions")}
      data-thread-completions
      hidden
      class="thread-command-list thread-command-completions"
    >
      <button
        :for={{command, label, _} <- ThreadCommands.all()}
        id={"thread-complete-#{command}"}
        type="button"
        role="option"
        aria-selected="false"
        data-thread-command={command}
      ><strong>/{command}</strong><span class="muted">{label}</span></button>
    </div>
    <div
      :if={@query}
      id="thread-skill-suggestions"
      class="thread-command-list"
      role="listbox"
      aria-label={dgettext("agents", "Skill suggestions")}
    >
      <p :if={matching_skills(@skills, @query) == []} class="muted">
        {dgettext("agents", "No matching skills. Use /skills to inspect the catalog.")}
      </p>
      <button
        :for={skill <- matching_skills(@skills, @query)}
        id={"thread-skill-choice-#{skill_value(skill, :id)}"}
        type="button"
        role="option"
        aria-selected="false"
        data-thread-skill={skill_value(skill, :id)}
        phx-click="select_skill"
        phx-value-id={skill_value(skill, :id)}
      ><strong>{skill_value(skill, :name)}</strong><span class="muted break">{skill_value(
        skill,
        :path,
        skill_value(skill, :scope, dgettext("agents", "Managed skill"))
      )}</span></button>
    </div>
    <div
      :if={@selected_skills != []}
      id="thread-selected-skills"
      class="row actions thread-selected-skills"
    >
      <span :for={skill <- @selected_skills}><strong>${skill_value(skill, :name)}</strong>
      <button
        type="button"
        class="console-button compact ghost"
        phx-click="remove_selected_skill"
        phx-value-id={skill_value(skill, :id)}
        aria-label={dgettext("agents", "Remove %{skill}", skill: skill_value(skill, :name))}
      >{dgettext("agents", "Remove")}</button></span>
    </div>
    """
  end

  @spec question_identity(map() | nil) :: String.t() | nil
  defp question_identity(nil), do: nil
  defp question_identity(question), do: question.id

  @spec collaboration_label(atom()) :: String.t()
  defp collaboration_label(:plan), do: dgettext("agents", "Plan")
  defp collaboration_label(_), do: dgettext("agents", "Work")

  @spec dialog_title(atom()) :: String.t()
  defp dialog_title(:context), do: dgettext("agents", "Thread context")
  defp dialog_title(:skills), do: dgettext("agents", "Skills")
  defp dialog_title(:help), do: dgettext("agents", "Composer help")

  @spec context_status_label(term()) :: String.t()
  defp context_status_label(:pending), do: dgettext("agents", "Pending")
  defp context_status_label(:ready), do: dgettext("agents", "Ready")
  defp context_status_label(_), do: dgettext("agents", "Unknown")

  @spec context_usage(map(), atom()) :: String.t()
  defp context_usage(info, key) do
    case skill_value(skill_value(info, :usage, %{}), key) do
      value when is_integer(value) -> Integer.to_string(value)
      _ -> dgettext("agents", "Unknown")
    end
  end

  @spec context_warning(term()) :: String.t()
  defp context_warning(value) when is_binary(value), do: value

  defp context_warning(%{} = value),
    do:
      skill_value(
        value,
        :message,
        dgettext("agents", "A context source could not be fully loaded.")
      )

  defp context_warning(_), do: dgettext("agents", "A context source could not be fully loaded.")

  @spec machine_summary(map()) :: String.t()
  defp machine_summary(params),
    do: "#{params["vcpu"]} CPU · #{params["memory_mib"]} MiB · #{params["disk_gib"]} GiB"

  @spec mode_hint(String.t()) :: String.t()
  defp mode_hint("low"), do: dgettext("agents", "Low is for small, well-defined tasks.")
  defp mode_hint("high"), do: dgettext("agents", "High gives difficult work more reasoning time.")
  defp mode_hint("ultra"), do: dgettext("agents", "Ultra is for complex, open-ended work.")
  defp mode_hint(_mode), do: dgettext("agents", "Medium is a good starting point for most work.")

  @spec status_label(atom()) :: String.t()
  defp status_label(:pending), do: dgettext("agents", "Pending")
  defp status_label(:provisioning), do: dgettext("agents", "Provisioning")
  defp status_label(:ready), do: dgettext("agents", "Ready")
  defp status_label(:failed), do: dgettext("agents", "Failed")
  defp status_label(:deleting), do: dgettext("agents", "Archiving")
  defp status_label(:archived), do: dgettext("agents", "Archived")
  defp status_label(_), do: dgettext("agents", "Unknown")

  @spec status_description(atom()) :: String.t()
  defp status_description(:pending), do: dgettext("agents", "Waiting for a workspace")

  defp status_description(:provisioning),
    do: dgettext("agents", "Preparing a machine for this task")

  defp status_description(:ready),
    do: dgettext("agents", "Workspace ready · open the conversation")

  defp status_description(:failed), do: dgettext("agents", "Workspace setup needs attention")
  defp status_description(:deleting), do: dgettext("agents", "Archiving · releasing the machine")
  defp status_description(:archived), do: dgettext("agents", "Archived · conversation retained")

  @spec event_role(atom()) :: String.t()
  defp event_role(:prompt), do: dgettext("agents", "Prompt")
  defp event_role(:assistant), do: dgettext("agents", "Agent")

  @spec event_text(Marshall.Agents.Event.t()) :: String.t()
  defp event_text(%{kind: :prompt, body: body}), do: Map.get(body, "prompt", "")

  defp event_text(%{kind: :assistant, body: body}),
    do: body |> Map.get("text", "") |> String.replace(["<proposed_plan>", "</proposed_plan>"], "")

  defp event_text(%{kind: :turn_started}), do: dgettext("agents", "Agent started working")
  defp event_text(%{kind: :model_output}), do: dgettext("agents", "Response received")

  defp event_text(%{kind: :tool_queued, body: %{"calls" => calls}}) when is_list(calls) do
    names =
      Enum.flat_map(calls, fn
        %{"tool" => tool} when is_binary(tool) -> [String.slice(tool, 0, 80)]
        _ -> []
      end)

    if names == [],
      do: dgettext("agents", "Tools queued"),
      else: dgettext("agents", "Queued: %{tools}", tools: Enum.join(names, ", "))
  end

  defp event_text(%{kind: :tool_queued}), do: dgettext("agents", "Tools queued")

  defp event_text(%{kind: :tool_result, body: %{"result" => %{"status" => "failed"}}}),
    do: dgettext("agents", "Tool failed")

  defp event_text(%{kind: :tool_result, body: %{"result" => %{"status" => "cancelled"}}}),
    do: dgettext("agents", "Tool cancelled")

  defp event_text(%{kind: :tool_result, body: %{"result" => %{"status" => "completed"}}}),
    do: dgettext("agents", "Tool completed")

  defp event_text(%{kind: :tool_result, body: %{"result" => %{"status" => "uncertain"}}}),
    do: dgettext("agents", "Tool outcome uncertain")

  defp event_text(%{kind: :tool_result}), do: dgettext("agents", "Tool result received")
  defp event_text(%{kind: :child_spawned}), do: dgettext("agents", "Delegated a task")
  defp event_text(%{kind: :turn_finished}), do: dgettext("agents", "Turn complete")

  defp event_text(%{kind: :turn_failed}),
    do: dgettext("agents", "The agent encountered a problem")

  defp event_text(%{kind: :waiting_for_vm}), do: dgettext("agents", "Waiting for the machine")
  defp event_text(%{kind: :planning_question}), do: dgettext("agents", "Waiting for your answers")
  defp event_text(%{kind: :planning_answer}), do: dgettext("agents", "Your answers were received")
  defp event_text(%{kind: :context_compacted}), do: dgettext("agents", "Older context summarized")

  defp event_text(%{kind: :context_reloaded}),
    do: dgettext("agents", "Workspace context reloaded")

  defp event_text(_event), do: dgettext("agents", "Thread updated")

  # @cc [owner:ghuntley,label:product] localized-access-role-labels
  # Visible access roles MUST use translated labels while role attributes and
  # action values retain the authoritative domain atoms.
  @spec role_label(atom()) :: String.t()
  defp role_label(:web), do: dgettext("agents", "Web apps")
  defp role_label(:viewer), do: dgettext("agents", "Viewer")
  defp role_label(:operator), do: dgettext("agents", "Operator")
  defp role_label(:manager), do: dgettext("agents", "Manager")
  defp role_label(:revoked), do: dgettext("agents", "Revoked")
  defp role_label(_), do: dgettext("agents", "Unknown")
end
