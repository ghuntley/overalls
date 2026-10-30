defmodule Marshall.Scim.Oidc do
  @moduledoc """
  OpenID Connect authorization-code sign-in for SCIM-provisioned identities.

  `begin/1` discovers the configured provider and returns an authorization URL
  plus a one-shot browser-session flow (state, nonce, PKCE verifier and the
  configuration it was started for). `complete/3` checks the returned state,
  exchanges the code at the provider token endpoint with the client secret,
  verifies the ID token against the provider JWKS and then requires `sub` to
  equal the SCIM `externalId` of an existing active account. There is no
  automatic registration. Success mints an Ash session token with `amr=oidc`.
  """
  require Ash.Query
  require Marshall.Events
  alias AshAuthentication.TokenResource.Actions
  alias Marshall.Accounts.{Token, User}
  alias Marshall.Authorization.SystemActor
  alias Marshall.Scim.Configuration
  alias Marshall.Scim.Oidc.{IdToken, Provider, VerifiedClaims}

  @flow_ttl_seconds 600

  @typedoc "Browser-session flow state; it holds only random values and configuration identity."
  @type flow :: %{required(String.t()) => String.t() | integer()}
  @type error ::
          :scim_disabled
          | :oidc_not_configured
          | :invalid_oidc_flow
          | :oidc_state_mismatch
          | :oidc_provider_error
          | :oidc_configuration_changed
          | :unknown_oidc_subject
          | :inactive_oidc_subject
          | Provider.error()
          | IdToken.error()

  @type settings :: %{
          issuer: String.t(),
          client_id: String.t(),
          client_secret: String.t()
        }

  @doc "Returns the enabled, fully configured OIDC client settings, if any."
  @spec settings() :: {:ok, settings()} | {:error, :scim_disabled | :oidc_not_configured}
  def settings do
    Configuration
    |> Ash.Query.filter(state == :enabled)
    |> Ash.read_one(actor: SystemActor.compute())
    |> case do
      {:ok, nil} ->
        {:error, :scim_disabled}

      {:ok,
       %Configuration{oidc_issuer: issuer, oidc_client_id: client_id, oidc_client_secret: secret}}
      when is_binary(issuer) and is_binary(client_id) and is_binary(secret) and issuer != "" and
             client_id != "" and secret != "" ->
        if valid_issuer?(issuer),
          do: {:ok, %{issuer: issuer, client_id: client_id, client_secret: secret}},
          else: {:error, :oidc_not_configured}

      _ ->
        {:error, :oidc_not_configured}
    end
  end

  @doc "True when SCIM is enabled and OIDC sign-in can be started."
  @spec available?() :: boolean()
  def available?, do: match?({:ok, _}, settings())

  @doc "Accepts only absolute HTTPS issuer URLs without credentials, query or fragment."
  @spec valid_issuer?(term()) :: boolean()
  def valid_issuer?(issuer) when is_binary(issuer) and byte_size(issuer) <= 2048 do
    case URI.new(issuer) do
      {:ok, %URI{scheme: "https", host: host, userinfo: nil, query: nil, fragment: nil}}
      when is_binary(host) and host != "" ->
        true

      _ ->
        false
    end
  end

  def valid_issuer?(_), do: false

  @spec begin(String.t()) :: {:ok, String.t(), flow()} | {:error, error()}
  def begin(redirect_uri) when is_binary(redirect_uri) do
    case start_flow(redirect_uri) do
      {:ok, _url, _flow} = ok ->
        ok

      {:error, reason} = error ->
        Marshall.Events.emit("auth.sign_in_failed", reason: event_reason(reason))
        error
    end
  end

  @spec start_flow(String.t()) :: {:ok, String.t(), flow()} | {:error, error()}
  defp start_flow(redirect_uri) do
    with {:ok, settings} <- settings(),
         {:ok, metadata} <- Provider.discover(settings.issuer) do
      state = random()
      nonce = random()
      verifier = random()

      query =
        URI.encode_query(%{
          "client_id" => settings.client_id,
          "redirect_uri" => redirect_uri,
          "response_type" => "code",
          "scope" => "openid",
          "state" => state,
          "nonce" => nonce,
          "code_challenge" => challenge(verifier),
          "code_challenge_method" => "S256"
        })

      url = metadata.authorization_endpoint |> URI.parse() |> URI.append_query(query)

      flow = %{
        "state" => state,
        "nonce" => nonce,
        "verifier" => verifier,
        "issuer" => settings.issuer,
        "client_id" => settings.client_id,
        "started_at" => System.system_time(:second)
      }

      {:ok, URI.to_string(url), flow}
    end
  end

  # @cc [owner:ghuntley,label:security] scim-oidc-code-flow
  # Sign-in MUST consume one session flow whose state matches, exchange the
  # code with the client secret and PKCE verifier, verify the ID token and
  # resolve sub only to an existing active SCIM externalId. Query parameters
  # MUST NOT supply identity claims; unknown subjects MUST NOT register.
  @spec complete(term(), map(), String.t()) :: {:ok, User.t(), binary()} | {:error, error()}
  def complete(flow, params, redirect_uri) when is_map(params) and is_binary(redirect_uri) do
    case verify_callback(flow, params, redirect_uri) do
      {:ok, user, _token} = ok ->
        Marshall.Events.emit("auth.signed_in", user_id: user.id)
        ok

      {:error, reason} = error ->
        Marshall.Events.emit("auth.sign_in_failed", reason: event_reason(reason))
        error
    end
  end

  def complete(_, _, _) do
    Marshall.Events.emit("auth.sign_in_failed", reason: :state_mismatch)
    {:error, :invalid_oidc_flow}
  end

  @spec verify_callback(term(), map(), String.t()) ::
          {:ok, User.t(), binary()} | {:error, error()}
  defp verify_callback(flow, params, redirect_uri) do
    with {:ok, flow} <- valid_flow(flow),
         :ok <- provider_error(params),
         :ok <- state_matches(flow, params["state"]),
         {:ok, code} <- code(params),
         {:ok, settings} <- settings(),
         :ok <- same_configuration(flow, settings),
         {:ok, metadata} <- Provider.discover(settings.issuer),
         {:ok, id_token} <-
           Provider.exchange_code(metadata, %{
             code: code,
             verifier: flow["verifier"],
             redirect_uri: redirect_uri,
             client_id: settings.client_id,
             client_secret: settings.client_secret
           }),
         {:ok, jwks} <- Provider.jwks(metadata),
         {:ok, claims} <-
           IdToken.verify(id_token, jwks, %{
             issuer: settings.issuer,
             client_id: settings.client_id,
             nonce: flow["nonce"],
             now: System.system_time(:second)
           }) do
      sign_in(claims)
    end
  end

  @doc "Resolves verified claims to an existing active SCIM account."
  @spec authenticate(VerifiedClaims.t()) :: {:ok, User.t()} | {:error, error()}
  def authenticate(%VerifiedClaims{issuer: issuer, subject: subject}) do
    with {:ok, settings} <- settings(),
         :ok <- if(settings.issuer == issuer, do: :ok, else: {:error, :issuer_mismatch}),
         {:ok, user} <- find_subject(subject) do
      if user.active and is_nil(user.deleted_at) and is_nil(user.scim_retirement_deadline),
        do: {:ok, user},
        else: {:error, :inactive_oidc_subject}
    end
  end

  @doc "Mints and stores a browser login token for verified claims."
  @spec sign_in(VerifiedClaims.t()) :: {:ok, User.t(), binary()} | {:error, error() | term()}
  def sign_in(%VerifiedClaims{} = claims) do
    with {:ok, user} <- authenticate(claims),
         {:ok, token, _claims} <- AshAuthentication.Jwt.token_for_user(user, %{"amr" => "oidc"}),
         :ok <-
           Actions.store_token(Token, %{"token" => token, "purpose" => "user"}) do
      {:ok, user, token}
    end
  end

  @spec valid_flow(term()) :: {:ok, flow()} | {:error, :invalid_oidc_flow}
  defp valid_flow(
         %{
           "state" => state,
           "nonce" => nonce,
           "verifier" => verifier,
           "issuer" => issuer,
           "client_id" => client_id,
           "started_at" => started_at
         } = flow
       )
       when is_binary(state) and is_binary(nonce) and is_binary(verifier) and is_binary(issuer) and
              is_binary(client_id) and is_integer(started_at) do
    age = System.system_time(:second) - started_at

    if age >= 0 and age <= @flow_ttl_seconds,
      do: {:ok, flow},
      else: {:error, :invalid_oidc_flow}
  end

  defp valid_flow(_), do: {:error, :invalid_oidc_flow}

  @spec provider_error(map()) :: :ok | {:error, :oidc_provider_error}
  defp provider_error(%{"error" => _}), do: {:error, :oidc_provider_error}
  defp provider_error(_), do: :ok

  @spec state_matches(flow(), term()) :: :ok | {:error, :oidc_state_mismatch}
  defp state_matches(%{"state" => expected}, actual)
       when is_binary(actual) and byte_size(actual) == byte_size(expected) do
    if Plug.Crypto.secure_compare(expected, actual),
      do: :ok,
      else: {:error, :oidc_state_mismatch}
  end

  defp state_matches(_, _), do: {:error, :oidc_state_mismatch}

  @spec code(map()) :: {:ok, String.t()} | {:error, :invalid_oidc_flow}
  defp code(%{"code" => code}) when is_binary(code) and byte_size(code) in 1..4096,
    do: {:ok, code}

  defp code(_), do: {:error, :invalid_oidc_flow}

  @spec same_configuration(flow(), settings()) :: :ok | {:error, :oidc_configuration_changed}
  defp same_configuration(flow, settings) do
    if flow["issuer"] == settings.issuer and flow["client_id"] == settings.client_id,
      do: :ok,
      else: {:error, :oidc_configuration_changed}
  end

  @spec find_subject(String.t()) :: {:ok, User.t()} | {:error, :unknown_oidc_subject}
  defp find_subject(subject) do
    User
    |> Ash.Query.for_read(:internal_lookup, %{}, actor: SystemActor.compute())
    |> Ash.Query.filter(scim_external_id == ^subject and not is_nil(scim_external_id))
    |> Ash.read(actor: SystemActor.compute())
    |> case do
      {:ok, [%User{} = user]} -> {:ok, user}
      _ -> {:error, :unknown_oidc_subject}
    end
  end

  @spec random() :: String.t()
  defp random, do: 32 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)

  @spec challenge(String.t()) :: String.t()
  defp challenge(verifier),
    do: :sha256 |> :crypto.hash(verifier) |> Base.url_encode64(padding: false)

  # Event reasons are coarse categories from the shared diagnostics enum
  # schema; they carry no provider error text, code, token or claim content.
  @spec event_reason(error()) ::
          :disabled
          | :not_configured
          | :state_mismatch
          | :denied
          | :unavailable
          | :invalid_token
          | :unknown_user
          | :refused
  defp event_reason(:scim_disabled), do: :disabled
  defp event_reason(:oidc_not_configured), do: :not_configured
  defp event_reason(:oidc_configuration_changed), do: :state_mismatch
  defp event_reason(:invalid_oidc_flow), do: :state_mismatch
  defp event_reason(:oidc_state_mismatch), do: :state_mismatch
  defp event_reason(:oidc_provider_error), do: :denied
  defp event_reason(:provider_unavailable), do: :unavailable
  defp event_reason(:invalid_provider_metadata), do: :unavailable
  defp event_reason(:token_exchange_failed), do: :unavailable
  defp event_reason(:unknown_oidc_subject), do: :unknown_user
  defp event_reason(:inactive_oidc_subject), do: :unknown_user

  defp event_reason(reason)
       when reason in [
              :malformed_id_token,
              :unsupported_algorithm,
              :no_matching_key,
              :invalid_signature,
              :issuer_mismatch,
              :audience_mismatch,
              :expired,
              :issued_in_future,
              :nonce_mismatch,
              :invalid_subject
            ],
       do: :invalid_token

  defp event_reason(_), do: :refused
end
