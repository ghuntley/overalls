defmodule MarshallWeb.ScimOidcControllerTest do
  use MarshallWeb.ConnCase, async: false

  alias Marshall.Accounts.{Login, User}
  alias Marshall.Scim.Configuration

  @issuer "https://idp.example.test"
  @client_id "overalls-client"
  @client_secret "client-secret-value"
  @subject "directory-subject-1"
  @kid "fake-idp-key"

  setup do
    previous = Application.get_env(:marshall, Marshall.Scim.Oidc)

    Application.put_env(:marshall, Marshall.Scim.Oidc,
      req_options: [plug: {Req.Test, Marshall.Scim.Oidc}]
    )

    on_exit(fn ->
      if previous,
        do: Application.put_env(:marshall, Marshall.Scim.Oidc, previous),
        else: Application.delete_env(:marshall, Marshall.Scim.Oidc)
    end)

    key = JOSE.JWK.generate_key({:rsa, 2048}) |> JOSE.JWK.merge(%{"kid" => @kid})

    config =
      Ash.Seed.seed!(Configuration, %{
        state: :enabled,
        oidc_issuer: @issuer,
        oidc_client_id: @client_id,
        oidc_client_secret: @client_secret
      })

    user =
      Ash.Seed.seed!(User, %{
        email: "oidc-#{Ash.UUID.generate()}@example.test",
        scim_external_id: @subject,
        active: true
      })

    %{key: key, config: config, user: user}
  end

  test "a verified code exchange signs in the matching SCIM user", %{conn: conn} = ctx do
    {conn, flow} = start(conn, ctx)
    assert flow["code_challenge_method"] == "S256"
    assert flow["scope"] == "openid"
    assert flow["client_id"] == @client_id

    conn = callback(conn, flow["state"])
    assert redirected_to(conn) == "/overview"

    assert_received {:token_request, request}
    assert request.params["grant_type"] == "authorization_code"
    assert request.params["code"] == "auth-code"
    assert request.params["redirect_uri"] == flow["redirect_uri"]
    assert request.authorization == "Basic " <> Base.encode64("#{@client_id}:#{@client_secret}")

    assert challenge(request.params["code_verifier"]) == flow["code_challenge"]

    token = get_session(conn, "user_token")
    assert {:ok, _jti, _expiry} = Login.verify(token, ctx.user)
    assert {:ok, %{"amr" => "oidc"}} = AshAuthentication.Jwt.peek(token)
    refute get_session(conn, :scim_oidc_flow)
  end

  test "query-supplied identity claims without a code never sign in", %{conn: conn} = ctx do
    {conn, flow} = start(conn, ctx)

    conn =
      get(conn, ~p"/auth/oidc/callback", %{
        "state" => flow["state"],
        "iss" => @issuer,
        "sub" => @subject,
        "nonce" => flow["nonce"]
      })

    assert_refused(conn)
    refute_received {:token_request, _}
  end

  test "a token signed by another key is rejected", %{conn: conn} = ctx do
    forger = JOSE.JWK.generate_key({:rsa, 2048}) |> JOSE.JWK.merge(%{"kid" => @kid})
    {conn, flow} = start(conn, ctx, signer: forger)
    assert_refused(callback(conn, flow["state"]))
  end

  test "an unsigned alg=none token is rejected", %{conn: conn} = ctx do
    {conn, flow} = start(conn, ctx, unsigned: true)
    assert_refused(callback(conn, flow["state"]))
  end

  test "an HS256 token keyed with the public modulus is rejected", %{conn: conn} = ctx do
    {_, public} = ctx.key |> JOSE.JWK.to_public() |> JOSE.JWK.to_map()
    hmac = JOSE.JWK.from_oct(public["n"])
    {conn, flow} = start(conn, ctx, signer: hmac, alg: "HS256")
    assert_refused(callback(conn, flow["state"]))
  end

  for {name, override} <- [
        {"wrong audience", %{"aud" => "another-client"}},
        {"wrong issuer", %{"iss" => "https://evil.example.test"}},
        # Times are offsets resolved when the token is minted: a module-body
        # System.system_time/1 is fixed at compile time, and a suite running
        # past the hour would carry a stale "future" iat inside the skew.
        {"expired token", %{"exp" => {:from_now, -3600}}},
        {"future issue time", %{"iat" => {:from_now, 3600}}},
        {"mismatched nonce", %{"nonce" => "not-the-session-nonce"}},
        {"missing nonce", %{"nonce" => :drop}},
        {"unknown subject", %{"sub" => "someone-else"}},
        {"untrusted extra audience", %{"aud" => [@client_id, "other"]}}
      ] do
    @override override
    test "#{name} is rejected", %{conn: conn} = ctx do
      {conn, flow} = start(conn, ctx, claims: @override)
      assert_refused(callback(conn, flow["state"]))
    end
  end

  test "a mismatched state is refused before any code exchange", %{conn: conn} = ctx do
    {conn, _flow} = start(conn, ctx)
    assert_refused(callback(conn, "forged-state"))
    refute_received {:token_request, _}
  end

  test "a callback without a started flow is refused", %{conn: conn} = ctx do
    stub_idp(ctx, %{nonce: "n"}, [])
    assert_refused(get(conn, ~p"/auth/oidc/callback", %{"state" => "s", "code" => "c"}))
    refute_received {:token_request, _}
  end

  test "the session flow is one-shot and cannot be replayed", %{conn: conn} = ctx do
    {conn, flow} = start(conn, ctx)
    first = callback(conn, flow["state"])
    assert redirected_to(first) == "/overview"

    # The browser keeps the cookie issued with the callback response, which no
    # longer carries the flow. (Replaying an older cookie is bounded by the
    # provider's single-use code and the ten-minute flow lifetime.)
    replay =
      first
      |> recycle()
      |> get(~p"/auth/oidc/callback", %{"state" => flow["state"], "code" => "auth-code"})

    assert redirected_to(replay) == "/sign-in"

    assert Phoenix.Flash.get(replay.assigns.flash, :error) ==
             "Single sign-on could not authenticate you."

    assert_received {:token_request, _}
    refute_received {:token_request, _}
  end

  test "an inactive SCIM user is refused", %{conn: conn} = ctx do
    Ash.Seed.update!(ctx.user, %{active: false})
    {conn, flow} = start(conn, ctx)
    assert_refused(callback(conn, flow["state"]))
  end

  test "a user pending SCIM retirement is refused", %{conn: conn} = ctx do
    Ash.Seed.update!(ctx.user, %{scim_retirement_deadline: DateTime.utc_now()})
    {conn, flow} = start(conn, ctx)
    assert_refused(callback(conn, flow["state"]))
  end

  test "a provider error response is refused", %{conn: conn} = ctx do
    {conn, flow} = start(conn, ctx)

    conn =
      get(conn, ~p"/auth/oidc/callback", %{"state" => flow["state"], "error" => "access_denied"})

    assert_refused(conn)
    refute_received {:token_request, _}
  end

  test "discovery advertising a different issuer is refused", %{conn: conn} = ctx do
    stub_idp(ctx, %{}, discovery_issuer: "https://other.example.test")
    conn = get(conn, ~p"/auth/oidc/start")
    assert redirected_to(conn) == "/sign-in"

    assert Phoenix.Flash.get(conn.assigns.flash, :error) ==
             "Single sign-on is not configured."
  end

  test "SCIM disabled refuses start and callback", %{conn: conn} = ctx do
    {conn, flow} = start(conn, ctx)
    Ash.Seed.update!(ctx.config, %{state: :disabled})
    assert_refused(callback(conn, flow["state"]))

    conn = get(build_conn(), ~p"/auth/oidc/start")
    assert redirected_to(conn) == "/sign-in"
  end

  test "a configuration change during the flow is refused", %{conn: conn} = ctx do
    {conn, flow} = start(conn, ctx)
    Ash.Seed.update!(ctx.config, %{oidc_client_id: "replacement-client"})
    assert_refused(callback(conn, flow["state"]))
  end

  test "start without a client secret is not configured", %{conn: conn} = ctx do
    Ash.Seed.update!(ctx.config, %{oidc_client_secret: nil})
    conn = get(conn, ~p"/auth/oidc/start")
    assert redirected_to(conn) == "/sign-in"
    refute get_session(conn, :scim_oidc_flow)
  end

  # -- fake identity provider -------------------------------------------------

  defp start(conn, ctx, opts \\ []) do
    parent = self()
    agent = start_supervised!({Agent, fn -> nil end})
    stub_idp(ctx, agent, Keyword.put(opts, :parent, parent))

    conn = get(conn, ~p"/auth/oidc/start")
    location = redirected_to(conn, 302)
    assert String.starts_with?(location, @issuer <> "/oauth/authorize?")
    flow = location |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query()
    Agent.update(agent, fn _ -> flow end)
    {recycle(conn), flow}
  end

  defp callback(conn, state),
    do: get(conn, ~p"/auth/oidc/callback", %{"state" => state, "code" => "auth-code"})

  defp assert_refused(conn) do
    assert redirected_to(conn) == "/sign-in"

    assert Phoenix.Flash.get(conn.assigns.flash, :error) ==
             "Single sign-on could not authenticate you."

    refute get_session(conn, "user_token")
  end

  defp stub_idp(ctx, flow_source, opts) do
    parent = Keyword.get(opts, :parent, self())
    discovery_issuer = Keyword.get(opts, :discovery_issuer, @issuer)
    public = JOSE.JWK.to_public(ctx.key)

    Req.Test.stub(Marshall.Scim.Oidc, fn conn ->
      case conn.request_path do
        "/.well-known/openid-configuration" ->
          Req.Test.json(conn, %{
            "issuer" => discovery_issuer,
            "authorization_endpoint" => @issuer <> "/oauth/authorize",
            "token_endpoint" => @issuer <> "/oauth/token",
            "jwks_uri" => @issuer <> "/oauth/jwks",
            "token_endpoint_auth_methods_supported" => ["client_secret_basic"]
          })

        "/oauth/jwks" ->
          {_, map} = JOSE.JWK.to_map(public)
          Req.Test.json(conn, %{"keys" => [map]})

        "/oauth/token" ->
          {:ok, body, conn} = Plug.Conn.read_body(conn)

          send(
            parent,
            {:token_request,
             %{
               params: URI.decode_query(body),
               authorization: conn |> Plug.Conn.get_req_header("authorization") |> List.first()
             }}
          )

          flow = if is_pid(flow_source), do: Agent.get(flow_source, & &1), else: flow_source

          Req.Test.json(conn, %{"id_token" => id_token(ctx, flow, opts), "token_type" => "Bearer"})

        _ ->
          Plug.Conn.send_resp(conn, 404, "")
      end
    end)
  end

  defp id_token(ctx, flow, opts) do
    now = System.system_time(:second)

    claims =
      %{
        "iss" => @issuer,
        "sub" => @subject,
        "aud" => @client_id,
        "exp" => now + 300,
        "iat" => now,
        "nonce" => flow_nonce(flow)
      }
      |> Map.merge(Keyword.get(opts, :claims, %{}))
      |> Enum.reject(fn {_, value} -> value == :drop end)
      |> Map.new(fn
        {claim, {:from_now, offset}} -> {claim, now + offset}
        claim -> claim
      end)

    if Keyword.get(opts, :unsigned, false) do
      encode = &Base.url_encode64(Jason.encode!(&1), padding: false)
      encode.(%{"alg" => "none", "kid" => @kid}) <> "." <> encode.(claims) <> "."
    else
      signer = Keyword.get(opts, :signer, ctx.key)
      alg = Keyword.get(opts, :alg, "RS256")

      {_, token} =
        signer
        |> JOSE.JWT.sign(%{"alg" => alg, "kid" => @kid}, claims)
        |> JOSE.JWS.compact()

      token
    end
  end

  defp flow_nonce(%{"nonce" => nonce}), do: nonce
  defp flow_nonce(%{nonce: nonce}), do: nonce
  defp flow_nonce(_), do: nil

  defp challenge(verifier),
    do: :sha256 |> :crypto.hash(verifier) |> Base.url_encode64(padding: false)
end
