defmodule MarshallWeb.MachinesLive do
  use MarshallWeb, :live_view
  alias Marshall.{Access, Compute, Teams, Threads}
  on_mount({MarshallWeb.LiveUserAuth, :live_user_required})
  on_mount(MarshallWeb.MachineWorkspace)
  alias MarshallWeb.{MachineDefaults, MachineWorkspace}
  alias MarshallWeb.CloneComponents

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Process.send_after(self(), :refresh, 1000)

    {:ok,
     socket
     |> assign(
       vm: nil,
       clone_form: to_form(%{"name" => "", "request_key" => Ash.UUID.generate()}, as: :clone),
       clones_empty: true,
       clones_available: true,
       clone_announcement: "",
       catalog_available: false,
       provisioning_teams: [],
       cursor: nil,
       next_cursor: nil,
       grant_cursor: nil,
       grant_next: nil,
       grant_owner: nil,
       grants_empty: false,
       empty: true,
       catalog: %{
         images: [],
         capacity_known: false,
         available: %{vcpu: 0, memory_bytes: 0, disk_bytes: 0}
       },
       relocation_key: Ash.UUID.generate(),
       relocation_retry_key: Ash.UUID.generate(),
       lifecycle_key: Ash.UUID.generate(),
       provision_error: nil
     )
     |> assign(metadata_form: to_form(%{"labels" => "", "comment" => ""}, as: :metadata))
     |> new_form()
     |> share_form()
     |> stream(:machines, [])
     |> stream(:grants, [])
     |> stream(:clones, [])}
  end

  @impl true
  def handle_params(%{"id" => id}, _uri, %{assigns: %{live_action: :resources}} = socket) do
    # Resources now live on the Settings page; keep old links working.
    {:noreply, push_navigate(socket, to: ~p"/machines/#{id}/settings")}
  end

  # @cc [owner:ghuntley,label:product;observability] machines-params-refresh-on-view-change
  # A params change MUST refresh when it changes the view (action, machine or
  # cursor). A patch that only changes form params (creation validation and
  # request-key seeding) MUST NOT reload the page data; the timer still
  # refreshes it, so revoked access is removed on the next tick.
  def handle_params(params, _uri, socket) do
    cursor = valid_cursor(params["after"])
    view = {socket.assigns.live_action, params["id"], cursor}

    socket =
      if socket.assigns[:loaded_view] == view do
        socket
      else
        socket |> assign(vm_id: params["id"], cursor: cursor, loaded_view: view) |> refresh()
      end

    socket =
      if socket.assigns.live_action == :settings do
        values =
          Map.merge(
            socket.assigns.clone_form.params,
            Map.take(params["clone"] || %{}, ["name", "request_key"])
          )

        socket = assign(socket, clone_form: to_form(values, as: :clone))

        if connected?(socket) and
             get_in(params, ["clone", "request_key"]) != values["request_key"] do
          push_patch(socket,
            to: ~p"/machines/#{params["id"]}/settings?#{%{clone: values}}",
            replace: true
          )
        else
          socket
        end
      else
        socket
      end

    if socket.assigns.live_action == :new do
      submitted = creation_params(params["machine"])

      values =
        socket.assigns.form.params
        |> seed_machine_defaults(socket.assigns, submitted)
        |> Map.merge(submitted)
        |> MachineDefaults.creation_defaults(socket.assigns.catalog.images)

      socket =
        assign(socket,
          form: to_form(values, as: :machine),
          machine_defaults_seeded: true,
          page_title: dgettext("machines", "Create machine")
        )

      if connected?(socket) and
           creation_params(params["machine"])["request_key"] != values["request_key"] do
        {:noreply, push_patch(socket, to: ~p"/machines/new?#{%{machine: values}}", replace: true)}
      else
        {:noreply, socket}
      end
    else
      {:noreply,
       assign(socket,
         page_title:
           if(socket.assigns.vm,
             do: socket.assigns.vm.name,
             else: dgettext("machines", "Machines")
           )
       )}
    end
  end

  @impl true
  # @cc [owner:ghuntley,label:observability] machines-refresh-after-completion
  # The next refresh MUST be scheduled only after the current one finishes, so
  # a slow refresh delays the next tick instead of queueing refreshes back to back.
  def handle_info(:refresh, socket) do
    socket = refresh(socket)
    # Back off while the database is unavailable instead of adding load.
    Process.send_after(
      self(),
      :refresh,
      if(socket.assigns[:refresh_failed], do: 5000, else: 1000)
    )

    {:noreply, socket}
  end

  # @cc [owner:ghuntley,label:security;durability] provision-through-thread
  # Machine creation MUST parse complete integer resource inputs and pass the
  # request key, authenticated actor, setup objective and canonical machine
  # specification to Threads.create_thread. Thread provisioning owns machine
  # admission and initial agent execution; displayed capacity and HTML limits
  # MUST NOT replace transactional domain admission.

  # @cc [owner:ghuntley,label:product;capacity] provision-form-image-minimum-refusal
  # Before any setup thread exists, a submitted size MUST be checked against the
  # selected image's durable catalog minima with Images.check_requirements/2, the
  # rule admission enforces. An unavailable image or a size below its minima MUST
  # create no thread and no machine and MUST render the predefined localized
  # reason on the form with the draft retained. Passing this check grants no
  # admission: the worker's transactional refusal remains authoritative.
  @impl true
  def handle_event("provision", %{"machine" => %{} = params}, socket) do
    params = MachineDefaults.creation_defaults(params, socket.assigns.catalog.images)
    socket = assign(socket, form: to_form(params, as: :machine), provision_error: nil)

    with {memory, ""} <- integer(params["memory_mib"]),
         {disk, ""} <- integer(params["disk_gib"]),
         {vcpu, ""} <- integer(params["vcpu"]),
         :ok <-
           image_requirements(params["image_id"], memory * 1_048_576, disk * 1_073_741_824),
         {:ok, thread} <-
           Threads.create_thread(
             %{
               objective: setup_objective(params["objective"]),
               mode: :medium,
               collaboration_mode: :work,
               idempotency_key: params["request_key"],
               machine_spec: %{
                 architecture: :x86_64,
                 image_id: params["image_id"],
                 profile: params["profile"],
                 team_id: blank_to_nil(params["team_id"]),
                 vcpu: vcpu,
                 memory_bytes: memory * 1_048_576,
                 disk_bytes: disk * 1_073_741_824
               }
             },
             actor: socket.assigns.current_user
           ) do
      {:noreply,
       socket
       |> put_flash(:info, dgettext("machines", "Machine and setup thread requested."))
       |> push_navigate(to: ~p"/machines/provisioning/#{thread.id}")}
    else
      {:refused, reason} ->
        {:noreply, assign(socket, provision_error: image_refusal_message(reason))}

      {:error, error} ->
        {:noreply, put_flash(socket, :error, error_message(error))}

      _ ->
        {:noreply,
         put_flash(
           socket,
           :error,
           dgettext("machines", "Enter whole numbers for CPU, memory and disk size.")
         )}
    end
  end

  # @cc [owner:ghuntley,label:product] creation-draft-retention
  # Draft changes MUST preserve the request identity and all allowed resource
  # fields through validation, periodic refresh and browser reload. URL values
  # MUST NOT bypass authenticated transactional admission. An explicit profile
  # selection into or out of Inception resets its image and size defaults, and an
  # explicit image change resets the size defaults to that image's minima;
  # subsequent size edits MUST remain intact.
  def handle_event("validate", %{"machine" => params}, socket) do
    socket = assign(socket, provision_error: nil)
    previous = socket.assigns.form.params
    values = Map.merge(previous, creation_params(params))

    values =
      cond do
        values["profile"] != previous["profile"] and
            "inception" in [values["profile"], previous["profile"]] ->
          values
          |> Map.drop(~w(image_id vcpu memory_mib disk_gib))
          |> Map.put(
            "image_id",
            MachineDefaults.default_image(values["profile"], socket.assigns.catalog.images)
          )
          |> MachineDefaults.creation_defaults(socket.assigns.catalog.images)

        values["image_id"] != previous["image_id"] ->
          values
          |> Map.drop(~w(vcpu memory_mib disk_gib))
          |> MachineDefaults.creation_defaults(socket.assigns.catalog.images)

        true ->
          values
      end

    {:noreply, push_patch(socket, to: ~p"/machines/new?#{%{machine: values}}", replace: true)}
  end

  # @cc [owner:ghuntley,label:security] lifecycle-current-actor
  # lifecycle MUST send the server-selected VM, request key and current actor to
  # Compute.lifecycle even when the UI showed management permission previously.
  def handle_event("lifecycle", %{"kind" => kind, "key" => key}, socket) do
    case Compute.lifecycle(%{vm_id: socket.assigns.vm_id, kind: kind, idempotency_key: key},
           actor: socket.assigns.current_user
         ) do
      {:ok, _} ->
        {:noreply,
         socket
         |> assign(lifecycle_key: Ash.UUID.generate())
         |> put_flash(:info, dgettext("machines", "Machine update requested."))
         |> refresh()}

      {:error, error} ->
        {:noreply, put_flash(socket, :error, error_message(error))}
    end
  end

  def handle_event("save-reflection-metadata", %{"metadata" => params}, socket) do
    labels =
      params["labels"] |> to_string() |> String.split(",", trim: true) |> Enum.map(&String.trim/1)

    case Compute.update_reflection_metadata(
           %{id: socket.assigns.vm_id, labels: labels, comment: params["comment"] || ""},
           actor: socket.assigns.current_user
         ) do
      {:ok, _} ->
        {:noreply,
         socket |> put_flash(:info, dgettext("machines", "Machine metadata saved.")) |> refresh()}

      {:error, error} ->
        {:noreply, put_flash(socket, :error, error_message(error))}
    end
  end

  # @cc [owner:ghuntley,label:security;recovery] clone-form-durable-request-identity
  # Clone submission MUST use the current actor and the form's retained key.
  # Duplicate events MUST reuse that key; a new intentional submission receives
  # a new key. Refresh and validation MUST NOT change a pending submission's key.
  def handle_event("clone-validate", %{"clone" => params}, socket) do
    values =
      Map.merge(socket.assigns.clone_form.params, Map.take(params, ["name", "request_key"]))

    {:noreply,
     push_patch(socket,
       to: ~p"/machines/#{socket.assigns.vm_id}/settings?#{%{clone: values}}",
       replace: true
     )}
  end

  def handle_event("clone", %{"clone" => params}, socket) do
    name = if params["name"] in [nil, ""], do: nil, else: params["name"]

    case Compute.clone(
           %{vm_id: socket.assigns.vm_id, name: name, idempotency_key: params["request_key"]},
           actor: socket.assigns.current_user
         ) do
      {:ok, _} ->
        values = %{"name" => "", "request_key" => Ash.UUID.generate()}

        {:noreply,
         socket
         |> put_flash(:info, dgettext("machines", "Clone queued. You can queue another copy."))
         |> refresh()
         |> push_patch(
           to: ~p"/machines/#{socket.assigns.vm_id}/settings?#{%{clone: values}}",
           replace: true
         )}

      {:error, error} ->
        {:noreply, put_flash(socket, :error, error_message(error))}
    end
  end

  def handle_event(event, %{"id" => id}, socket) when event in ["clone-retry", "clone-cancel"] do
    action = if event == "clone-retry", do: :retry_clone, else: :cancel_clone

    case apply(Compute, action, [%{request_id: id}, [actor: socket.assigns.current_user]]) do
      {:ok, _} -> {:noreply, refresh(socket)}
      {:error, error} -> {:noreply, put_flash(socket, :error, error_message(error))}
    end
  end

  # @cc [owner:ghuntley,label:security] relocation-controls-current-domain-authority
  # Relocate, Cancel and Retry MUST invoke authorized Compute actions with the current
  # actor. The server selects the VM and displayed relocation; client flags MUST
  # NOT grant permission or select a destination. Retain admission keys on errors.
  def handle_event("relocate", _, socket) do
    case Compute.relocate(
           %{vm_id: socket.assigns.vm_id, idempotency_key: socket.assigns.relocation_key},
           actor: socket.assigns.current_user
         ) do
      {:ok, _} ->
        {:noreply,
         socket
         |> assign(relocation_key: Ash.UUID.generate())
         |> put_flash(
           :info,
           dgettext("machines", "Relocation requested. A destination is selected automatically.")
         )
         |> refresh()}

      {:error, error} ->
        {:noreply, put_flash(socket, :error, error_message(error))}
    end
  end

  def handle_event("cancel-relocation", _, socket) do
    relocation = socket.assigns.vm && socket.assigns.vm.relocation

    if relocation do
      case Compute.cancel_relocation(%{relocation_id: relocation.id},
             actor: socket.assigns.current_user
           ) do
        {:ok, _} ->
          {:noreply,
           socket
           |> put_flash(
             :info,
             dgettext("machines", "Cancellation requested. Cleanup may continue after recovery.")
           )
           |> refresh()}

        {:error, error} ->
          {:noreply, put_flash(socket, :error, error_message(error))}
      end
    else
      {:noreply, put_flash(socket, :error, dgettext("machines", "No relocation is available."))}
    end
  end

  def handle_event("retry-relocation", _, socket) do
    relocation = socket.assigns.vm && socket.assigns.vm.relocation

    if relocation do
      case Compute.retry_relocation(
             %{
               relocation_id: relocation.id,
               idempotency_key: socket.assigns.relocation_retry_key
             },
             actor: socket.assigns.current_user
           ) do
        {:ok, _} ->
          {:noreply,
           socket
           |> assign(relocation_retry_key: Ash.UUID.generate())
           |> put_flash(
             :info,
             dgettext(
               "machines",
               "Destination restart requested. The source copy remains retained until readiness succeeds."
             )
           )
           |> refresh()}

        {:error, error} ->
          {:noreply, put_flash(socket, :error, error_message(error))}
      end
    else
      {:noreply, put_flash(socket, :error, dgettext("machines", "No relocation is available."))}
    end
  end

  # @cc [owner:ghuntley,label:security] sharing-through-authorized-domain
  # share MUST delegate recipient resolution, role validation and current VM
  # management permission to Access.set_access with the current actor and key.
  # Browser form fields MUST NOT be treated as trusted account or grant records.
  def handle_event("share", %{"access" => %{} = params}, socket) do
    case Access.set_access(
           %{
             vm_id: socket.assigns.vm_id,
             email: params["email"],
             role: params["role"],
             idempotency_key: params["request_key"]
           },
           actor: socket.assigns.current_user
         ) do
      {:ok, _} ->
        {:noreply,
         socket
         |> share_form()
         |> put_flash(:info, dgettext("machines", "Access updated."))
         |> refresh()}

      {:error, error} ->
        {:noreply, put_flash(socket, :error, error_message(error))}
    end
  end

  # The shared MachineWorkspace hook takes this event on detail pages, where the
  # header shows the toggle; the list page reaches here and re-reads its rows so
  # the pinned section and the keyset page stay disjoint (ADR-0193).
  def handle_event("pin", %{"id" => id, "pinned" => pinned}, socket)
      when is_binary(id) and is_binary(pinned) do
    {:noreply, socket |> MachineWorkspace.toggle_pin(id, pinned == "true") |> refresh()}
  end

  def handle_event("grants_next", _, socket),
    do: {:noreply, socket |> assign(grant_cursor: socket.assigns.grant_next) |> refresh()}

  def handle_event("grants_first", _, socket),
    do: {:noreply, socket |> assign(grant_cursor: nil) |> refresh()}

  def handle_event(_, _, socket),
    do: {:noreply, put_flash(socket, :error, dgettext("machines", "Invalid request."))}

  defp integer(value) when is_binary(value) and byte_size(value) <= 12, do: Integer.parse(value)
  defp integer(_), do: :error

  defp creation_params(params) when is_map(params) do
    params
    |> Map.take(~w(objective image_id profile vcpu memory_mib disk_gib request_key team_id))
    |> Enum.filter(fn {key, value} ->
      is_binary(value) and byte_size(value) <= if(key == "objective", do: 65_536, else: 128) and
        (key != "request_key" or OverallsProtocol.uuid?(value)) and
        (key != "team_id" or value == "" or OverallsProtocol.uuid?(value))
    end)
    |> Map.new()
  end

  defp creation_params(_), do: %{}

  @spec refresh(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  defp refresh(socket) do
    view =
      case socket.assigns.live_action do
        :index -> :machines
        :new -> :machine_new
        _ -> :machine
      end

    Marshall.Observability.measure_refresh(view, fn ->
      socket |> load() |> assign(:refresh_failed, false)
    end)
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

  # @cc [owner:ghuntley,label:reliability;security] machines-refresh-fails-closed
  # A database or authorization failure during refresh MUST degrade the page
  # instead of crashing the LiveView. The list MUST be cleared rather than show
  # rows from an earlier refresh, and a machine page MUST leave for the list
  # rather than keep VM details it could not reauthorize.
  @spec unavailable(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  defp unavailable(%{assigns: %{live_action: :new}} = socket),
    do: assign(socket, catalog_available: false, refresh_failed: true)

  defp unavailable(%{assigns: %{live_action: :index}} = socket) do
    socket
    |> assign(catalog_available: false, empty: false, next_cursor: nil, refresh_failed: true)
    |> stream(:machines, [], reset: true)
    |> put_flash(:error, dgettext("machines", "Machines are temporarily unavailable."))
  end

  defp unavailable(socket) do
    socket
    |> assign(:refresh_failed, true)
    |> put_flash(:error, dgettext("machines", "Machines are temporarily unavailable."))
    |> push_navigate(to: ~p"/machines")
  end

  defp load(%{assigns: %{live_action: :new}} = socket) do
    actor = socket.assigns.current_user

    case {Compute.catalog(%{}, actor: actor), Teams.list_teams(%{limit: 100}, actor: actor)} do
      {{:ok, catalog}, {:ok, teams}} ->
        teams = Enum.filter(teams, &(&1.role in [:owner, :admin]))
        assign(socket, catalog: catalog, catalog_available: true, provisioning_teams: teams)

      _ ->
        assign(socket, catalog_available: false)
    end
  end

  # @cc [owner:ghuntley,label:product] machines-pinned-first
  # The list page MUST read the caller's pinned section first and exclude those
  # ids from every keyset page, so a pinned machine appears once, before the
  # unpinned rows, and only on the first page. Later pages MUST keep the same
  # exclusion so paging neither repeats nor skips a machine.
  defp load(%{assigns: %{live_action: :index}} = socket) do
    actor = socket.assigns.current_user

    with {:ok, %{items: pinned, ids: pinned_ids}} <- Compute.pinned_vms(%{}, actor: actor),
         {:ok, page} <-
           Compute.list_vms(
             %{after: socket.assigns.cursor, exclude: pinned_ids},
             actor: actor
           ),
         {:ok, catalog} <- Compute.catalog(%{}, actor: actor) do
      items = if(socket.assigns.cursor, do: [], else: pinned) ++ page.items

      socket
      |> assign(
        catalog: catalog,
        catalog_available: true,
        next_cursor: page.next_cursor,
        empty: items == []
      )
      |> stream(:machines, items, reset: true)
    else
      _ ->
        socket
        |> assign(catalog_available: false)
        |> put_flash(:error, dgettext("machines", "Machines are temporarily unavailable."))
    end
  end

  # @cc [owner:ghuntley,label:security] refresh-removes-revoked-views
  # Detail refresh MUST refetch current VM access and redirect when it fails.
  # Grant details MUST be cleared when management permission disappears, the VM
  # is deleted, or the authorized grant query fails.
  defp load(socket) do
    case Compute.get_vm(%{vm_id: socket.assigns.vm_id}, actor: socket.assigns.current_user) do
      {:ok, vm} ->
        socket = MachineWorkspace.put_vm(socket, vm)

        socket =
          case socket.assigns.live_action == :settings && vm.permissions.manage &&
                 Compute.list_clones(%{vm_id: vm.id}, actor: socket.assigns.current_user) do
            {:ok, %{requests: requests}} ->
              socket
              |> assign(
                clones_empty: requests == [],
                clones_available: true,
                clone_announcement: CloneComponents.announcement(requests)
              )
              |> stream(:clones, requests, reset: true)

            _ ->
              socket
              |> assign(clones_empty: true, clones_available: false, clone_announcement: "")
              |> stream(:clones, [], reset: true)
          end

        if socket.assigns.live_action == :access and vm.permissions.manage and
             vm.desired_state != :deleted do
          case Access.list_grants(%{vm_id: vm.id, after: socket.assigns.grant_cursor},
                 actor: socket.assigns.current_user
               ) do
            {:ok, page} ->
              socket
              |> assign(
                grant_owner: page.owner,
                grant_next: page.next_cursor,
                grants_empty: page.items == []
              )
              |> stream(:grants, page.items, reset: true)

            _ ->
              socket
              |> assign(grant_owner: nil, grant_next: nil, grants_empty: false)
              |> stream(:grants, [], reset: true)
          end
        else
          socket
          |> assign(grant_owner: nil, grant_next: nil, grants_empty: false)
          |> stream(:grants, [], reset: true)
        end

      _ ->
        MachineWorkspace.return_after_access_loss(socket, :read)
    end
  end

  # @cc [owner:ghuntley,label:product;security] browser-new-default-profile
  # A fresh machine form MUST use the account's machine preset, defaulting to
  # Standard (Work). Explicit supported selections MUST survive draft changes,
  # reloads and submission without changing the saved preset.
  defp new_form(socket),
    do:
      assign(socket,
        machine_defaults_seeded: false,
        form:
          to_form(
            %{
              "objective" => "",
              "team_id" => "",
              "request_key" => Ash.UUID.generate()
            },
            as: :machine
          )
      )

  @spec setup_objective(term()) :: String.t()
  defp setup_objective(objective) when is_binary(objective) do
    case String.trim(objective) do
      "" ->
        "No initial setup requested. Do not make changes to this machine; report that no setup was requested."

      value ->
        value
    end
  end

  defp setup_objective(_), do: setup_objective("")

  @spec seed_machine_defaults(map(), map(), map()) :: map()
  defp seed_machine_defaults(values, %{machine_defaults_seeded: true}, _submitted), do: values

  defp seed_machine_defaults(values, assigns, submitted) do
    defaults =
      MachineDefaults.for_user(
        assigns.current_user,
        :machine,
        assigns.catalog.images
      )

    # Explicit image/profile links receive that environment's ordinary size
    # defaults rather than the saved shape of a different environment.
    defaults =
      if Map.has_key?(submitted, "image_id") or Map.has_key?(submitted, "profile") do
        defaults
        |> Map.drop(~w(vcpu memory_mib disk_gib))
        |> Map.merge(submitted)
        |> then(fn params ->
          if params["profile"] == "inception",
            do:
              Map.put(
                params,
                "image_id",
                MachineDefaults.default_image("inception", assigns.catalog.images)
              ),
            else: params
        end)
      else
        defaults
      end

    Map.merge(defaults, values)
  end

  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: value

  # @cc [owner:ghuntley,label:product] creation-form-agent-profiles
  # Form creation opens a user thread, which always binds an agent root, and
  # ADR-0099 gives Customer VMs none; the form MUST NOT offer Customer.
  defp profile_options(images) do
    ordinary = [
      {dgettext("machines", "Standard"), "standard"},
      {"OSS", "oss"}
    ]

    if Enum.any?(images, &(&1.id == Marshall.Compute.Profiles.inception_image_id())),
      do: ordinary ++ [{dgettext("machines", "Inception"), "inception"}],
      else: ordinary
  end

  @spec profile_description(String.t()) :: String.t()
  defp profile_description("customer"),
    do:
      dgettext(
        "machines",
        "Private and owner-only. SSH and terminal access; no outbound connections, sharing, web apps, or AI agent."
      )

  defp profile_description("standard"),
    do:
      dgettext(
        "machines",
        "Outbound connections, sharing, web apps, SSH, terminal, and AI agent tools. The agent cannot start child agents."
      )

  defp profile_description("oss"),
    do:
      dgettext(
        "machines",
        "The same network and access options as Standard, with AI agents that can start child agents."
      )

  defp profile_description("inception"),
    do:
      dgettext(
        "machines",
        "A Overalls development environment for nested machines. It uses a dedicated image, an extra 256 GiB data disk, and higher resource minimums. Its AI agent can start child agents."
      )

  defp share_form(socket),
    do:
      assign(socket,
        access_form:
          to_form(%{"email" => "", "role" => "viewer", "request_key" => Ash.UUID.generate()},
            as: :access
          )
      )

  defp valid_cursor(value), do: if(OverallsProtocol.uuid?(value), do: value)

  defp image_options(images, selected) do
    options =
      Enum.map(images, fn image ->
        name =
          if Map.get(image, :android, false),
            do: dgettext("machines", "Android (API 36)"),
            else: image.name

        {name, image.id}
      end)

    if is_binary(selected) and selected != "" and not Enum.any?(images, &(&1.id == selected)),
      do: [{dgettext("machines", "Selected image unavailable"), selected} | options],
      else: options
  end

  defp gib(bytes), do: Float.round(bytes / 1_073_741_824, 1)

  @spec role_label(atom()) :: String.t()
  defp role_label(:web), do: dgettext("machines", "Web apps")
  defp role_label(:viewer), do: dgettext("machines", "Viewer")
  defp role_label(:operator), do: dgettext("machines", "Operator")
  defp role_label(:manager), do: dgettext("machines", "Manager")
  defp role_label(:revoked), do: dgettext("machines", "Revoked")
  defp role_label(_), do: dgettext("machines", "Unknown")

  @spec role_summary(atom()) :: String.t()
  defp role_summary(:web), do: dgettext("machines", "Open this machine's web apps. No terminal.")
  defp role_summary(:viewer), do: dgettext("machines", "Read the terminal.")
  defp role_summary(:operator), do: dgettext("machines", "Read and write in the terminal.")

  defp role_summary(:manager),
    do: dgettext("machines", "Terminal, lifecycle, resize, clone and sharing.")

  defp role_summary(:revoked),
    do: dgettext("machines", "Ends that person's access to this machine.")

  defp role_summary(_), do: ""
  defp label(:customer), do: dgettext("machines", "Customer")
  defp label(:inception), do: dgettext("machines", "Inception")
  defp label(:standard), do: dgettext("machines", "Standard")
  defp label(:oss), do: "OSS"
  defp state(%{desired_state: :deleted}), do: dgettext("machines", "Deleting")

  defp state(%{desired_state: :stopped, observed_state: :running}),
    do: dgettext("machines", "Stopping")

  defp state(%{desired_state: :running, observed_state: state})
       when state in [:pending, :stopped], do: dgettext("machines", "Starting")

  defp state(vm), do: MarshallWeb.WorkspaceComponents.machine_state(vm)

  @spec image_requirements(term(), pos_integer(), pos_integer()) ::
          :ok | {:refused, :image_unavailable | :image_requirements_not_met}
  defp image_requirements(image_id, memory_bytes, disk_bytes) do
    case Marshall.Compute.Images.check_requirements(image_id, %{
           architecture: :x86_64,
           memory_bytes: memory_bytes,
           disk_bytes: disk_bytes
         }) do
      :ok -> :ok
      {:error, reason} -> {:refused, reason}
    end
  end

  @spec image_refusal_message(:image_unavailable | :image_requirements_not_met) :: String.t()
  defp image_refusal_message(:image_unavailable),
    do:
      dgettext("machines", "This image is no longer available. Refresh and choose another image.")

  defp image_refusal_message(:image_requirements_not_met),
    do: dgettext("machines", "The selected image needs more memory or disk space.")

  # @cc [owner:ghuntley,label:security] fixed-machine-error-messages
  # error_message/1 MUST return only predefined public messages; raw exceptions,
  # SQL details, credential data and arbitrary error payloads MUST NOT be shown.
  defp error_message(error) do
    text = Exception.message(error)

    messages = [
      insufficient_capacity:
        dgettext("machines", "There is not enough available capacity for this machine."),
      image_unavailable:
        dgettext(
          "machines",
          "This image is no longer available. Refresh and choose another image."
        ),
      image_requirements_not_met:
        dgettext("machines", "The selected image needs more memory or disk space."),
      host_unavailable: dgettext("machines", "This machine's host is currently unavailable."),
      recipient_not_registered:
        dgettext("machines", "No registered account matches that email address."),
      owner_protected: dgettext("machines", "The owner's access cannot be changed."),
      forbidden: dgettext("machines", "You no longer have permission for this action."),
      vm_deleted: dgettext("machines", "This machine is being deleted."),
      machine_pinned: dgettext("machines", "Unpin this machine before deleting it."),
      idempotency_conflict:
        dgettext("machines", "This request has already been used. Refresh before trying again.")
    ]

    Enum.find_value(
      messages,
      dgettext("machines", "The request could not be completed. Check the values and try again."),
      fn {reason, message} ->
        if String.contains?(text, Atom.to_string(reason)), do: message
      end
    )
  end

  defp relocation_phase(phase) do
    %{
      preparing: dgettext("machines", "Preparing transfer"),
      checking_transfer: dgettext("machines", "Checking transfer connectivity"),
      stopping_source: dgettext("machines", "Stopping the source"),
      copying: dgettext("machines", "Copying the stopped disks"),
      importing: dgettext("machines", "Verifying the destination disks"),
      handoff: dgettext("machines", "Switching placement"),
      checking_destination: dgettext("machines", "Checking destination readiness"),
      activation_failed: dgettext("machines", "Destination boot failed; source copy retained"),
      readiness_failed:
        dgettext("machines", "Destination readiness failed; source copy retained"),
      source_cleanup: dgettext("machines", "Destination ready; cleaning up the source"),
      restoring_source: dgettext("machines", "Cancelling and restoring the source"),
      cancelled_cleanup: dgettext("machines", "Source restored; destination cleanup pending"),
      deleting_copies: dgettext("machines", "Deleting retained copies"),
      cancelled: dgettext("machines", "Move cancelled; cleanup complete"),
      complete: dgettext("machines", "Move complete"),
      deleted: dgettext("machines", "All retained copies deleted")
    }[phase]
  end

  # @cc [owner:ghuntley,label:product] creation-profile-explanations
  # The creation form MUST explain every offered profile using its enforced access,
  # network, and agent capabilities. It MUST omit Inception help when Inception is
  # unavailable and MUST keep the comparison accessible from the profile selector.
  @impl true
  @spec render(map()) :: Phoenix.LiveView.Rendered.t()
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      compute={true}
      current_scope={%{user: @current_user}}
      time_zone={@time_zone}
      now={@now}
    >
      <section :if={@live_action == :index} class="stack">
        <UI.heading
          title={dgettext("machines", "Machines")}
          subtitle={dgettext("machines", "Your development environments, personal and shared.")}
        >
          <:actions>
            <.link id="create-machine" navigate={~p"/machines/new"} class="console-button primary">
              {dgettext("machines", "+ Create machine")}
            </.link>
          </:actions>
        </UI.heading>
        <p id="available-capacity" class="capacity-summary muted">
          <span :if={@catalog_available && @catalog.capacity_known}>
            {dgettext(
              "machines",
              "Current headroom: %{value1} vCPU · %{value2} GiB memory · %{value3} GiB disk",
              value1: @catalog.available.vcpu,
              value2: gib(@catalog.available.memory_bytes),
              value3: gib(@catalog.available.disk_bytes)
            )}
          </span>
          <span :if={!@catalog_available || !@catalog.capacity_known}>{dgettext(
            "machines",
            "Current headroom is temporarily unavailable."
          )}</span>
        </p>
        <p :if={@empty} id="machines-empty" class="empty-state">
          {dgettext(
            "machines",
            "No machines on this page. Create a machine or ask an owner to share access."
          )}
        </p>
        <div class="machine-table">
          <table>
            <thead>
              <tr>
                <th class="width-auto">{dgettext("machines", "Machine")}</th>
                <th class="width-min">{dgettext("machines", "Status")}</th>
                <th class="width-min">{dgettext("machines", "Resources")}</th>
                <th class="width-min">{dgettext("machines", "Profile")}</th>
                <th class="width-min">{dgettext("machines", "Host")}</th>
                <th class="width-min">{dgettext("machines", "Access")}</th>
                <th class="width-min">{dgettext("machines", "Connect")}</th>
              </tr>
            </thead>
            <tbody id="machines" phx-update="stream">
              <tr
                :for={{id, vm} <- @streams.machines}
                id={id}
                class="machine-row"
                data-pinned={to_string(UI.pinned?(vm))}
              >
                <td>
                  <.link navigate={~p"/machines/#{vm.id}"} class="machine-name">{vm.name}</.link>
                  <UI.os_label vm={vm} id={"machine-os-#{vm.id}"} />
                </td>
                <td data-label={dgettext("machines", "Status")}>
                  <UI.pinned_label vm={vm} id={"machine-pinned-#{vm.id}"} />
                  <span
                    class="status-label"
                    data-state={vm.observed_state}
                    data-tone={UI.machine_tone(vm)}
                  >{state(vm)}</span>
                </td>
                <td class="resource-values" data-label={dgettext("machines", "Resources")}>
                  {dgettext("machines", "%{value1} vCPU · %{value2} GiB RAM · %{value3} GiB disk",
                    value1: vm.vcpu,
                    value2: gib(vm.memory_bytes),
                    value3: gib(vm.disk_bytes)
                  )}
                </td>
                <td data-label={dgettext("machines", "Profile")}>{label(vm.profile)}</td>
                <td
                  id={"machine-host-#{vm.id}"}
                  class="nowrap"
                  data-label={dgettext("machines", "Host")}
                >
                  <code>{vm.host || dgettext("machines", "Unavailable")}</code>
                </td>
                <td class="muted" data-label={dgettext("machines", "Access")}>
                  <%= if vm.owner do %>
                    {dgettext("machines", "Owner")}
                  <% else %>
                    {dgettext("machines", "Shared by")}
                    <.person
                      id={"machine-owner-#{vm.id}"}
                      email={vm.owner_email}
                      time_zone={vm.owner_time_zone}
                      viewer_zone={@time_zone}
                      now={@now}
                    />
                  <% end %>
                </td>
                <td data-label={dgettext("machines", "Connect")}>
                  <div class="machine-open-actions">
                    <.link
                      :if={
                        vm.desired_state in [:running, :paused] &&
                          vm.observed_state in [:running, :paused]
                      }
                      navigate={~p"/machines/#{vm.id}/terminals"}
                      id={"machine-terminal-#{vm.id}"}
                      class="console-button"
                      aria-label={
                        dgettext("machines", "Open terminal for %{value1}", value1: vm.name)
                      }
                    >{dgettext("machines", "Open terminal")}</.link>
                    <span
                      :if={
                        vm.desired_state not in [:running, :paused] ||
                          vm.observed_state not in [:running, :paused]
                      }
                      class="muted"
                    >{dgettext("machines", "Terminal unavailable")}</span>
                    <UI.machine_editor_action vm={vm} id_prefix="machine" />
                    <UI.pin_toggle vm={vm} id={"pin-#{vm.id}"} />
                  </div>
                </td>
              </tr>
            </tbody>
          </table>
        </div>
        <nav class="row" aria-label={dgettext("machines", "Machine pages")}>
          <.link :if={@cursor} patch={~p"/machines"} id="machines-first">{dgettext(
            "machines",
            "← First page"
          )}</.link>
          <.link :if={@next_cursor} patch={~p"/machines?#{%{after: @next_cursor}}"} id="machines-next">{dgettext(
            "machines",
            "Next page →"
          )}</.link>
        </nav>
      </section>
      <section :if={@live_action == :new} class="creation-page stack">
        <p><.link navigate={~p"/machines"}>{dgettext("machines", "← Machines")}</.link></p>
        <UI.heading
          title={dgettext("machines", "Create machine")}
          subtitle={dgettext("machines", "Choose an image and the resources for your environment.")}
        />
        <div class="panel">
          <p :if={!@catalog_available} role="status" class="console-notice">
            {dgettext(
              "machines",
              "Images and capacity are temporarily unavailable. Your choices are retained."
            )}
          </p>
          <p
            :if={@catalog_available && @catalog.images == []}
            id="no-ready-images"
            role="status"
            class="console-notice"
          >
            {dgettext("machines", "No images are available on ready hosts right now.")}
          </p>
          <p :if={@catalog_available && @catalog.capacity_known} class="capacity-summary muted">
            {dgettext(
              "machines",
              "Current headroom: %{value1} vCPU · %{value2} GiB memory · %{value3} GiB disk",
              value1: @catalog.available.vcpu,
              value2: gib(@catalog.available.memory_bytes),
              value3: gib(@catalog.available.disk_bytes)
            )}
          </p>
          <.form
            for={@form}
            id="provision-form"
            phx-submit="provision"
            phx-change="validate"
            class="stack"
          >
            <.input field={@form[:request_key]} type="hidden" />
            <.input
              field={@form[:objective]}
              type="textarea"
              label={dgettext("machines", "What should this machine do when it is ready?")}
              hint={
                dgettext(
                  "machines",
                  "The machine agent will execute this instruction automatically in Work mode."
                )
              }
              rows="5"
              maxlength="65536"
              aria-describedby="machine-setup-guide"
            />
            <p id="machine-setup-guide" class="muted">
              {dgettext(
                "machines",
                "Leave this blank to create the machine without making setup changes."
              )}
            </p>
            <h2 class="form-chapter">
              <span>1.</span> {dgettext("machines", "Choose your environment")}
            </h2>
            <.input
              :if={@form[:profile].value != "inception"}
              field={@form[:image_id]}
              type="select"
              label={dgettext("machines", "Image")}
              prompt={dgettext("machines", "Choose an image")}
              options={
                image_options(
                  Enum.reject(
                    @catalog.images,
                    &(&1.id == Marshall.Compute.Profiles.inception_image_id())
                  ),
                  @form[:image_id].value
                )
              }
              required
            />
            <.input
              field={@form[:profile]}
              type="select"
              label={dgettext("machines", "Profile")}
              options={profile_options(@catalog.images)}
              aria-describedby="profile-guide"
            />
            <div id="profile-guide" class="profile-guide">
              <p class="muted">
                {dgettext(
                  "machines",
                  "Profiles choose access and agent features. Machines remain isolated from one another."
                )}
              </p>
              <dl class="kv">
                <div
                  :for={{name, profile} <- profile_options(@catalog.images)}
                  id={"profile-help-#{profile}"}
                >
                  <dt>{name}</dt>
                  <dd>{profile_description(profile)}</dd>
                </div>
              </dl>
            </div>
            <h2 class="form-chapter"><span>2.</span> {dgettext("machines", "Make it yours")}</h2>
            <.input
              field={@form[:team_id]}
              type="select"
              label={dgettext("machines", "Owner")}
              options={[
                {dgettext("machines", "Personal"), ""}
                | Enum.map(@provisioning_teams, &{&1.name, &1.id})
              ]}
            />
            <.input
              :if={@form[:profile].value == "inception"}
              field={@form[:image_id]}
              type="hidden"
              id="inception-image-id"
            />
            <h2 class="form-chapter">
              <span>3.</span> {dgettext("machines", "Give it room to grow")}
            </h2>
            <div class="grid">
              <.input
                field={@form[:vcpu]}
                type="number"
                label={dgettext("machines", "CPU (vCPU)")}
                min={if @form[:profile].value == "inception", do: 16, else: 1}
                max="32"
                required
              />
              <.input
                field={@form[:memory_mib]}
                type="number"
                label={dgettext("machines", "Memory (MiB)")}
                min={if @form[:profile].value == "inception", do: 32768, else: 512}
                step="1"
                required
              />
              <.input
                field={@form[:disk_gib]}
                type="number"
                label={
                  if @form[:profile].value == "inception",
                    do: dgettext("machines", "Root disk (GiB)"),
                    else: dgettext("machines", "Disk (GiB)")
                }
                min={if @form[:profile].value == "inception", do: 64, else: 2}
                max={OverallsProtocol.VMShape.maximum_disk_gib()}
                step="1"
                required
              />
            </div>
            <div id="creation-summary" class="creation-summary panel dashed">
              <h3>{dgettext("machines", "Ready when you are")}</h3>
              <p>
                {dgettext("machines", "%{value1} vCPU · %{value2} MiB memory · %{value3} GiB disk",
                  value1: @form[:vcpu].value,
                  value2: @form[:memory_mib].value,
                  value3: @form[:disk_gib].value
                )}
              </p>
              <p class="muted">
                {dgettext("machines", "Your disk stays with you when the machine is stopped.")}
              </p>
            </div>
            <p :if={@provision_error} id="provision-error" role="alert" class="console-notice">
              {@provision_error}
            </p>
            <div class="row actions">
              <Layouts.action
                tone="primary"
                id="provision-submit"
                disabled={!@catalog_available || @catalog.images == []}
                phx-disable-with={dgettext("machines", "Creating…")}
              >
                {dgettext("machines", "Create machine")}
              </Layouts.action>
              <.link navigate={~p"/machines"} class="console-button">{dgettext("machines", "Cancel")}</.link>
            </div>
          </.form>
        </div>
      </section>
      <section :if={@live_action in [:access, :settings] && @vm} id="machine-detail" class="stack">
        <UI.machine_header
          vm={@vm}
          connection={@machine_connection}
          power_key={@machine_power_key}
          active={to_string(@live_action)}
        />
        <UI.panel
          :if={@live_action == :settings}
          id="machine-resources"
          title={dgettext("machines", "Resources")}
        >
          <:actions>
            <.link
              :if={@vm.permissions.manage && @vm.desired_state != :deleted}
              id="resize-machine"
              navigate={~p"/machines/#{@vm.id}/resize"}
              class="console-button"
            >
              {dgettext("machines", "Resize")}
            </.link>
          </:actions>
          <.kv>
            <:item title={dgettext("machines", "Operating system")}>
              <span id="machine-operating-system">{UI.operating_system(@vm) ||
                dgettext("machines", "Unavailable")}</span>
            </:item>
            <:item title={dgettext("machines", "CPU")}>
              {dgettext("machines", "%{value1} vCPU", value1: @vm.vcpu)}
            </:item>
            <:item title={dgettext("machines", "Memory")}>
              {dgettext("machines", "%{value1} GiB", value1: gib(@vm.memory_bytes))}
            </:item>
            <:item title={dgettext("machines", "Disk")}>
              {dgettext("machines", "%{value1} GiB", value1: gib(@vm.disk_bytes))}
            </:item>
            <:item title={dgettext("machines", "Host")}>
              <code id="machine-host">{@vm.host || dgettext("machines", "Unavailable")}</code>
            </:item>
            <:item title={dgettext("machines", "Profile")}>{label(@vm.profile)}</:item>
          </.kv>
          <p class="muted">
            {dgettext("machines", "Your disk is retained when the machine is stopped.")}
          </p>
        </UI.panel>
        <p
          :if={@live_action in [:access, :settings] && !@vm.permissions.manage}
          class="empty-state"
          role="status"
        >
          {dgettext("machines", "Management access is required to change the remaining settings.")}
        </p>
        <p :if={@vm.profile == :customer} id="customer-isolation" class="muted">
          {dgettext(
            "machines",
            "Customer machines allow only owner SSH and terminal access. Outbound networking, workspace sharing, and web service exposure are disabled."
          )}
        </p>
        <section
          :if={
            @live_action == :access && @vm.permissions.manage && @vm.desired_state != :deleted &&
              OverallsProtocol.ProfilePolicy.allows?(@vm.profile, :sharing)
          }
          id="sharing"
          class="stack"
        >
          <UI.heading
            title={dgettext("machines", "Access")}
            subtitle={dgettext("machines", "Who can reach this machine, and what each role allows.")}
          />
          <UI.panel id="access-people" title={dgettext("machines", "Direct machine grants")}>
            <p class="muted">
              {dgettext(
                "machines",
                "Team membership and thread sharing can also grant machine access."
              )}
            </p>
            <div class="machine-table access-table">
              <table>
                <thead>
                  <tr>
                    <th class="width-auto">{dgettext("machines", "Account")}</th>
                    <th class="width-min">{dgettext("machines", "Role")}</th>
                    <th class="width-min">{dgettext("machines", "Allows")}</th>
                  </tr>
                </thead>
                <tbody>
                  <tr :if={@grant_owner} id="machine-owner">
                    <td class="break" data-label={dgettext("machines", "Account")}>
                      <.person
                        id="machine-owner-person"
                        email={@grant_owner.email}
                        time_zone={@grant_owner.time_zone}
                        viewer_zone={@time_zone}
                        now={@now}
                      />
                    </td>
                    <td data-label={dgettext("machines", "Role")}>
                      <span class="status-label">{dgettext("machines", "Owner")}</span>
                    </td>
                    <td data-label={dgettext("machines", "Allows")} class="muted">
                      {dgettext("machines", "Everything; cannot be changed here.")}
                    </td>
                  </tr>
                </tbody>
                <tbody id="grants" phx-update="stream">
                  <tr :for={{id, grant} <- @streams.grants} id={id}>
                    <td class="break" data-label={dgettext("machines", "Account")}>
                      <.person
                        id={"#{id}-person"}
                        email={grant.email}
                        time_zone={grant.time_zone}
                        viewer_zone={@time_zone}
                        now={@now}
                      />
                    </td>
                    <td data-label={dgettext("machines", "Role")}>
                      <span class="status-label">{role_label(grant.role)}</span>
                    </td>
                    <td data-label={dgettext("machines", "Allows")} class="muted">
                      {role_summary(grant.role)}
                    </td>
                  </tr>
                </tbody>
              </table>
            </div>
            <p :if={@grants_empty} id="grants-empty" class="muted">
              {dgettext("machines", "No direct machine grants.")}
            </p>
            <div :if={@grant_cursor || @grant_next} class="row actions">
              <Layouts.action :if={@grant_cursor} tone="default" phx-click="grants_first">
                {dgettext("machines", "← First page")}
              </Layouts.action>
              <Layouts.action :if={@grant_next} tone="default" phx-click="grants_next">
                {dgettext("machines", "Next page →")}
              </Layouts.action>
            </div>
          </UI.panel>
          <.form for={@access_form} id="sharing-form" phx-submit="share" class="panel stack">
            <h2>{dgettext("machines", "Grant, change or remove access")}</h2>
            <p class="muted">
              {dgettext(
                "machines",
                "The account must already be registered. Saving a role replaces that person's direct machine role; choose Remove access to remove that direct grant."
              )}
            </p>
            <.input field={@access_form[:request_key]} type="hidden" />
            <div class="grid">
              <.input
                field={@access_form[:email]}
                type="email"
                label={dgettext("machines", "Registered email")}
                required
              />
              <.input
                field={@access_form[:role]}
                type="select"
                label={dgettext("machines", "Role")}
                options={[
                  {dgettext("machines", "Web apps only"), "web"},
                  {dgettext("machines", "Viewer"), "viewer"},
                  {dgettext("machines", "Operator"), "operator"},
                  {dgettext("machines", "Manager"), "manager"},
                  {dgettext("machines", "Remove access"), "revoked"}
                ]}
              />
            </div>
            <.kv>
              <:item title={dgettext("machines", "Web apps only")}>{role_summary(:web)}</:item>
              <:item title={dgettext("machines", "Viewer")}>{role_summary(:viewer)}</:item>
              <:item title={dgettext("machines", "Operator")}>{role_summary(:operator)}</:item>
              <:item title={dgettext("machines", "Manager")}>{role_summary(:manager)}</:item>
              <:item title={dgettext("machines", "Remove access")}>{role_summary(:revoked)}</:item>
            </.kv>
            <div class="row actions">
              <Layouts.action
                tone="primary"
                id="share-submit"
                phx-disable-with={dgettext("machines", "Saving…")}
              >
                {dgettext("machines", "Save access")}
              </Layouts.action>
            </div>
          </.form>
        </section>
        <section
          :if={@live_action == :settings && @vm.permissions.manage}
          id="machine-advanced"
          class="stack"
        >
          <.form
            for={@metadata_form}
            id="reflection-metadata"
            phx-submit="save-reflection-metadata"
            class="panel stack"
          >
            <h2>{dgettext("machines", "Reflection metadata")}</h2>
            <.input
              field={@metadata_form[:labels]}
              label={dgettext("machines", "Labels")}
              value={Enum.join(@vm.labels || [], ", ")}
              placeholder={dgettext("machines", "production, project-name")}
            />
            <.input
              field={@metadata_form[:comment]}
              label={dgettext("machines", "Comment")}
              value={@vm.comment || ""}
              type="textarea"
              placeholder={dgettext("machines", "Short description for agents")}
            />
            <Layouts.action tone="primary" id="reflection-metadata-submit">
              {dgettext("machines", "Save metadata")}
            </Layouts.action>
          </.form>
          <UI.panel id="relocation-controls" title={dgettext("machines", "Relocate machine")}>
            <:actions>
              <Layouts.action
                :if={
                  @vm.desired_state != :deleted &&
                    (!@vm.relocation || !@vm.relocation.active)
                }
                id="relocate-machine"
                phx-click="relocate"
                phx-disable-with={dgettext("machines", "Requesting…")}
                data-confirm={
                  dgettext(
                    "machines",
                    "Move this machine to an automatically selected host? The machine may be briefly unavailable."
                  )
                }
              >
                {dgettext("machines", "Move to another host")}
              </Layouts.action>
            </:actions>
            <p id="relocation-network-note" class="muted">
              {dgettext(
                "machines",
                "The machine is stopped, copied once and started on an automatically selected host. Our development fleet uses a 1 Gbit/s connection between hosts, so a move can take a little longer; moves are expected to be much faster when Overalls runs on AWS in production."
              )}
            </p>
            <div :if={@vm.relocation} id="relocation-status" class="stack" aria-live="polite">
              <.kv>
                <:item title={dgettext("machines", "Phase")}>
                  <span id="relocation-phase">{relocation_phase(@vm.relocation.phase)}</span>
                </:item>
                <:item title={dgettext("machines", "Mode")}>
                  <span id="relocation-mode">
                    {dgettext(
                      "machines",
                      "The machine is stopped, copied once and started on the destination."
                    )}
                  </span>
                </:item>
                <:item :if={@vm.relocation.downtime} title={dgettext("machines", "Observed downtime")}>
                  <span
                    id="relocation-downtime"
                    title={
                      dgettext(
                        "machines",
                        "Measured between control-plane stop and readiness observations; guest availability may differ."
                      )
                    }
                  >
                    {dgettext("machines", "%{seconds} seconds%{suffix}",
                      seconds: @vm.relocation.downtime.seconds,
                      suffix:
                        if(@vm.relocation.downtime.ongoing,
                          do: dgettext("machines", " and counting"),
                          else: ""
                        )
                    )}
                  </span>
                </:item>
              </.kv>
              <div :if={@vm.relocation.cancellable || @vm.relocation.retryable} class="row actions">
                <Layouts.action
                  :if={@vm.relocation.cancellable}
                  id="cancel-relocation"
                  phx-click="cancel-relocation"
                  phx-disable-with={dgettext("machines", "Cancelling…")}
                >
                  {dgettext("machines", "Cancel move")}
                </Layouts.action>
                <Layouts.action
                  :if={@vm.relocation.retryable}
                  id="retry-relocation"
                  phx-click="retry-relocation"
                  phx-disable-with={dgettext("machines", "Requesting restart…")}
                >
                  {dgettext("machines", "Retry destination boot")}
                </Layouts.action>
              </div>
            </div>
          </UI.panel>
          <section
            :if={@vm.desired_state != :deleted}
            id="clone-machine"
            class="panel clone-section"
            aria-labelledby="clone-heading"
          >
            <header>
              <h2 id="clone-heading">{dgettext("machines", "Clone machine")}</h2>
              <span class="muted">{dgettext(
                "machines",
                "Files and stored credentials are included in the copy"
              )}</span>
            </header>
            <div class="panel-body">
              <p>
                {dgettext(
                  "machines",
                  "Create a private, independent copy of this machine. Running machines stop briefly for each snapshot, then restart while copying continues. Copies are processed in order and match the source's power state when their turn begins."
                )}
              </p>
              <.form
                for={@clone_form}
                id="clone-form"
                phx-change="clone-validate"
                phx-submit="clone"
                class="field-row clone-form"
              >
                <.input field={@clone_form[:request_key]} type="hidden" />
                <.input
                  field={@clone_form[:name]}
                  label={dgettext("machines", "New machine name (optional)")}
                  placeholder={dgettext("machines", "Leave blank to generate a name")}
                  maxlength="63"
                  aria-describedby="clone-name-help clone-privacy"
                />
                <button
                  id="submit-clone"
                  type="submit"
                  class="console-button primary"
                  phx-disable-with={dgettext("machines", "Queuing…")}
                >
                  {dgettext("machines", "+ Queue clone")}
                </button>
              </.form>
              <p id="clone-name-help" class="sr-only">
                {dgettext("machines", "Leave blank to generate a name.")}
              </p>
              <p id="clone-privacy" class="sr-only">
                {dgettext("machines", "Files and stored credentials are included in the copy.")}
              </p>
            </div>
          </section>
          <section
            :if={@vm.desired_state != :deleted}
            class="panel"
            aria-labelledby="clone-requests-heading"
          >
            <header>
              <h2 id="clone-requests-heading">{dgettext("machines", "Clone requests")}</h2>
              <span class="muted">{dgettext("machines", "Updates automatically")}</span>
            </header>
            <div class="panel-body">
              <p :if={@clones_available && @clones_empty} id="clone-empty" class="empty-state">
                {dgettext(
                  "machines",
                  "No clone requests yet. Queue a copy and follow its progress here."
                )}
              </p>
              <p :if={!@clones_available} id="clone-unavailable" class="empty-state">
                {dgettext(
                  "machines",
                  "Clone requests are temporarily unavailable. Retrying automatically."
                )}
              </p>
              <%!-- Outside the reset stream: unchanged polls must not reannounce every card. --%>
              <p
                id="clone-announcement"
                class="sr-only"
                role="status"
                aria-live="polite"
                aria-atomic="true"
              >
                {@clone_announcement}
              </p>
              <div id="clone-requests" phx-update="stream" class="clone-requests">
                <CloneComponents.card
                  :for={{dom_id, clone} <- @streams.clones}
                  id={dom_id}
                  clone={clone}
                />
              </div>
            </div>
          </section>
          <UI.panel
            :if={@vm.desired_state != :deleted}
            class="danger danger-zone"
            title={dgettext("machines", "Delete machine")}
          >
            <:actions>
              <%!-- The owner's pin fences deletion server-side (ADR-0193); the
                   disabled control only explains that refusal ahead of time. --%>
              <Layouts.action
                tone="danger"
                id="delete-machine"
                phx-click="lifecycle"
                phx-value-kind="delete"
                phx-value-key={@lifecycle_key}
                disabled={@vm.owner && UI.pinned?(@vm)}
                aria-describedby={@vm.owner && UI.pinned?(@vm) && "delete-pinned"}
                data-confirm={
                  dgettext("machines", "Delete this machine and its disk? This cannot be undone.")
                }
              >
                {dgettext("machines", "Delete")}
              </Layouts.action>
            </:actions>
            <p :if={@vm.owner && UI.pinned?(@vm)} id="delete-pinned">
              {dgettext(
                "machines",
                "Unpin to delete. While you have this machine pinned, nothing can delete it."
              )}
            </p>
            <p class="muted">
              {dgettext(
                "machines",
                "Permanently remove this machine and its disk. This cannot be undone."
              )}
            </p>
          </UI.panel>
        </section>
      </section>
    </Layouts.app>
    """
  end
end
