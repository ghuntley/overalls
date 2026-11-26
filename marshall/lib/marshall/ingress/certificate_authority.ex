defmodule Marshall.Ingress.CertificateAuthority do
  @moduledoc "Database-backed, single-zone ACME work for the designated issuer queue."
  alias Marshall.Authorization.SystemActor
  alias Marshall.Compute.Ledger
  alias Marshall.Ingress.{FleetCertificate, FleetCertificateAccount}
  alias Marshall.Ingress.ACME.{AccountKey, Issuer, Material, Propagation, Request, Transport}
  require Marshall.Events

  @type error :: :unavailable | :invalid_state | :unknown_order | :invalid_material

  # @cc [owner:ghuntley,label:security;recovery] wildcard-issuer-database-custody
  # Only the configured issuer queue may perform ACME work. Account, CSR key and
  # complete certificate bytes MUST exist solely as Cloak ciphertext in the
  # database between jobs; jobs contain the resource ID only. An uncertain
  # newOrder response MUST NOT trigger a second newOrder for that generation.
  @spec step(binary()) :: :ok | {:error, error()}
  def step(id) do
    with {:ok, config} <- configuration(),
         %FleetCertificate{} = row <- one(id),
         true <- row.zone == config.zone do
      case row.status do
        :pending -> prepare(row, config)
        :challenging -> advance(row, config)
        :issued -> activate(row)
        _ -> :ok
      end
    else
      _ -> {:error, :unavailable}
    end
  rescue
    _ -> {:error, :unavailable}
  catch
    :exit, _ -> {:error, :unavailable}
  end

  defp configuration do
    case Application.get_env(:marshall, :fleet_acme) do
      %{
        zone: zone,
        directory: directory,
        issuer_ca_file: ca_file,
        roots_file: roots_file,
        nameservers: peers,
        accept_terms: terms
      }
      when is_binary(zone) and is_binary(directory) and is_binary(ca_file) and
             is_binary(roots_file) and is_list(peers) and is_boolean(terms) ->
        with {:ok, transport} <- Transport.new(directory, cacertfile: ca_file),
             {:ok, roots} when byte_size(roots) in 1..1_048_576 <- File.read(roots_file),
             true <- length(peers) in 1..8 do
          {:ok,
           %{
             zone: zone,
             transport: transport,
             roots: roots,
             nameservers: peers,
             accept_terms: terms
           }}
        else
          _ -> {:error, :unavailable}
        end

      _ ->
        {:error, :unavailable}
    end
  end

  defp one(id), do: List.first(Ledger.read!(FleetCertificate, id: id))

  defp account(config) do
    directory = config.transport.directory

    row =
      case Ledger.read!(FleetCertificateAccount, issuer_url: directory) do
        [existing] -> existing
        [] when config.accept_terms -> create_account(directory)
        _ -> nil
      end

    with %FleetCertificateAccount{} <- row,
         loaded <- Ash.load!(row, [:private_key], actor: SystemActor.compute()),
         {:ok, key} <- AccountKey.from_private(loaded.private_key),
         true <- key.thumbprint == row.thumbprint do
      if config.accept_terms,
        do: Issuer.register(config.transport, key, true),
        else: Issuer.recover(config.transport, key)
    else
      _ -> {:error, :unavailable}
    end
  end

  defp create_account(directory) do
    key = AccountKey.generate()

    case Ledger.transaction(fn ->
           case Ledger.read!(FleetCertificateAccount, issuer_url: directory) do
             [existing] ->
               existing

             [] ->
               Ledger.create!(FleetCertificateAccount, :register, %{
                 issuer_url: directory,
                 private_key: key.private,
                 thumbprint: key.thumbprint
               })
           end
         end) do
      {:ok, row} -> row
      _ -> nil
    end
  end

  defp prepare(row, config) do
    if row.order_attempted_at do
      if DateTime.diff(Ledger.now(), row.order_attempted_at, :second) >= 3600,
        do: fail(row, :unknown_order),
        else: {:error, :unknown_order}
    else
      place_order(row, config)
    end
  end

  # @cc [owner:ghuntley,label:recovery] wildcard-uncertain-order-quarantine
  # A timed-out newOrder has no durable URL to poll. Never repeat it for the
  # same generation. After an hour, fail that generation visibly so the next
  # scheduled due check can allocate a new one under the database lock.
  defp place_order(row, config) do
    with {:ok, issuer} <- account(config),
         {:ok, request} <- request(row),
         :ok <- mark_attempt(row.id),
         {:ok, order} <- Issuer.create_order(issuer, request),
         {:ok, _} <-
           Ledger.transaction(fn ->
             current = Ledger.lock!(FleetCertificate, row.id)

             if current.status != :pending or is_nil(current.order_attempted_at),
               do: Ledger.rollback(:invalid_state)

             Ledger.update!(current, :bind_order, %{
               order_url: order.url,
               finalize_url: order.finalize,
               authorization_url: hd(order.authorizations)
             })
           end) do
      Marshall.Events.emit("ingress.fleet_certificate_ordered",
        certificate_id: row.id,
        generation: row.generation
      )

      :ok
    else
      {:error, :unknown_order} -> {:error, :unknown_order}
      _ -> {:error, :unavailable}
    end
  end

  defp request(row) do
    if row.csr_fingerprint do
      loaded = Ash.load!(row, [:csr_der, :private_key_pem], actor: SystemActor.compute())

      with {:ok, request} <-
             Request.restore(row.zone, loaded.csr_der, loaded.private_key_pem),
           true <- digest(request.der) == row.csr_fingerprint,
           do: {:ok, request},
           else: (_ -> {:error, :invalid_material})
    else
      with {:ok, request} <- Request.generate(row.zone),
           {:ok, _} <-
             Ledger.transaction(fn ->
               current = Ledger.lock!(FleetCertificate, row.id)

               if current.status != :pending or current.csr_fingerprint,
                 do: Ledger.rollback(:invalid_state)

               Ledger.update!(current, :save_request, %{
                 csr_der: request.der,
                 private_key_pem: request.private_key_pem,
                 csr_fingerprint: digest(request.der)
               })
             end),
           do: {:ok, request}
    end
  end

  defp mark_attempt(id) do
    case Ledger.transaction(fn ->
           current = Ledger.lock!(FleetCertificate, id)

           if current.status != :pending or not is_nil(current.order_attempted_at),
             do: Ledger.rollback(:unknown_order)

           Ledger.update!(current, :mark_order_attempt, %{order_attempted_at: Ledger.now()})
         end) do
      {:ok, _} -> :ok
      _ -> {:error, :unknown_order}
    end
  end

  defp advance(row, config) do
    with {:ok, issuer} <- account(config),
         {:ok, request} <- request(row),
         {:ok, order} <- Issuer.poll_order(issuer, seed(row)) do
      case order.status do
        "pending" -> pending(row, config, issuer, request, order)
        "ready" -> with({:ok, _} <- Issuer.finalize(issuer, order, request), do: :ok)
        "processing" -> :ok
        "valid" -> issued(row, config, issuer, request, order)
        "invalid" -> fail(row)
      end
    else
      _ -> {:error, :unavailable}
    end
  end

  defp seed(row),
    do: %{
      url: row.order_url,
      finalize: row.finalize_url,
      authorizations: [row.authorization_url],
      hostname: row.zone
    }

  # @cc [owner:ghuntley,label:recovery;observability] wildcard-proof-check-class
  # A negative proof check MUST withhold issuer acknowledgement, keep the
  # challenging generation retryable, and emit only its closed cause class and
  # certificate identity after the proof refresh transaction commits.
  defp pending(row, config, issuer, _request, order) do
    with {:ok, proof} <- Issuer.authorization(issuer, hd(order.authorizations), row.zone, true),
         true <- proof.status in ["pending", "valid"],
         {:ok, _} <-
           Ledger.transaction(fn ->
             current = Ledger.lock!(FleetCertificate, row.id)
             if current.status != :challenging, do: Ledger.rollback(:invalid_state)

             action = if is_nil(current.dns_proof), do: :record_proof, else: :refresh_proof

             if not is_nil(current.dns_proof) and current.dns_proof != proof.proof,
               do: Ledger.rollback(:invalid_state)

             values = %{proof_expires_at: DateTime.add(Ledger.now(), 120, :second)}

             values =
               if action == :record_proof,
                 do: Map.put(values, :dns_proof, proof.proof),
                 else: values

             Ledger.update!(current, action, values)
           end) do
      case Propagation.check(row.zone, [proof.proof], config.nameservers) do
        :ok ->
          case Issuer.acknowledge(issuer, proof) do
            {:ok, %{status: status}} when status in ["pending", "processing", "valid"] -> :ok
            _ -> {:error, :unavailable}
          end

        {:error, reason} ->
          Marshall.Events.emit("ingress.fleet_certificate_propagation_waiting",
            certificate_id: row.id,
            generation: row.generation,
            reason: reason
          )

          :ok
      end
    else
      _ -> {:error, :unavailable}
    end
  end

  defp issued(row, config, issuer, request, order) do
    with {:ok, %Material{} = material} <- Issuer.download(issuer, order, request, config.roots),
         chain <-
           :public_key.pem_encode(
             Enum.map(material.certificates, &{:Certificate, &1, :not_encrypted})
           ),
         {:ok, _} <-
           Ledger.transaction(fn ->
             current = Ledger.lock!(FleetCertificate, row.id)
             if current.status != :challenging, do: Ledger.rollback(:invalid_state)

             Ledger.update!(current, :finish_issued, %{
               chain_pem: chain,
               fingerprint: material.fingerprint,
               expires_at: DateTime.from_unix!(material.expires_at)
             })
           end) do
      Marshall.Events.emit("ingress.fleet_certificate_issued",
        certificate_id: row.id,
        generation: row.generation
      )

      activate(row)
    else
      _ -> {:error, :invalid_material}
    end
  end

  defp activate(row) do
    case Ledger.transaction(fn ->
           Marshall.Repo.query!(
             "SELECT pg_advisory_xact_lock(hashtextextended($1, 0))",
             ["audi-wildcard:" <> row.zone]
           )

           current = Ledger.lock!(FleetCertificate, row.id)
           if current.status != :issued, do: Ledger.rollback(:invalid_state)

           %{rows: [[latest]]} =
             Marshall.Repo.query!(
               "SELECT MAX(generation) FROM ingress_fleet_certificates WHERE zone = $1",
               [row.zone]
             )

           if current.generation != latest, do: Ledger.rollback(:invalid_state)

           for previous <- Ledger.read!(FleetCertificate, zone: row.zone, status: :active),
               do: Ledger.update!(Ledger.lock!(FleetCertificate, previous.id), :retire, %{})

           Ledger.update!(current, :activate, %{})
         end) do
      {:ok, _} ->
        Marshall.Events.emit("ingress.fleet_certificate_activated",
          certificate_id: row.id,
          generation: row.generation
        )

        :ok

      _ ->
        {:error, :invalid_state}
    end
  end

  defp fail(row, reason \\ :invalid_order) do
    case Ledger.transaction(fn ->
           current = Ledger.lock!(FleetCertificate, row.id)
           action = if reason == :unknown_order, do: :fail_unknown_order, else: :fail
           Ledger.update!(current, action, %{})
         end) do
      {:ok, _} ->
        Marshall.Events.emit("ingress.fleet_certificate_failed",
          certificate_id: row.id,
          generation: row.generation,
          reason: reason
        )

        :ok

      _ ->
        {:error, :invalid_state}
    end
  end

  defp digest(value), do: :crypto.hash(:sha256, value) |> Base.encode16(case: :lower)
end
