defmodule Susan.ProviderDeliveryTest do
  # Provider delivery evidence beyond the happy paths in poke_test.exs
  # (ADR-0224, ADR-0236, ADR-0278): provider credentials verify under the
  # configured keys, and each provider's unregistered-token and expired-token
  # answers reach the poke response. Every request goes to Susan.FakeProvider;
  # nothing here contacts APNs, FCM, WNS or a token endpoint.
  use Susan.DataCase, async: false

  alias Susan.{FakeProvider, Poke}

  @apns "https://api.push.apple.com"
  @fcm "https://fcm.googleapis.com"
  @wns "https://wns2-par02p.notify.windows.com"

  setup do
    config = Fixtures.config()
    %{config: config, install: Fixtures.install()}
  end

  @spec poke(Susan.Config.t(), {binary(), binary()}, keyword()) :: Susan.Poke.Machine.response()
  defp poke(config, install, key_options) do
    {push_key, _key} = Fixtures.push_key(config, key_options)
    Poke.handle(Fixtures.poke(push_key, install), config)
  end

  @spec jwt_parts(String.t()) :: {map(), map(), binary(), binary()}
  defp jwt_parts(token) do
    [header, claims, signature] = String.split(token, ".")

    {JSON.decode!(Base.url_decode64!(header, padding: false)),
     JSON.decode!(Base.url_decode64!(claims, padding: false)), header <> "." <> claims,
     Base.url_decode64!(signature, padding: false)}
  end

  @spec authorization(%{headers: [{String.t(), String.t()}]}) :: String.t()
  defp authorization(request), do: request.headers |> Map.new() |> Map.fetch!("authorization")

  describe "APNs" do
    test "the provider token is an ES256 JWT that the configured team key verifies", ctx do
      assert {:respond, 204, :empty, nil} = poke(ctx.config, ctx.install, provider: :apns)
      assert [request] = FakeProvider.requests()
      "bearer " <> token = authorization(request)

      {header, claims, input, <<r::256, s::256>>} = jwt_parts(token)
      assert header == %{"alg" => "ES256", "kid" => "ABCDEFGHIJ", "typ" => "JWT"}
      assert %{"iss" => "TEAM123456", "iat" => iat} = claims
      assert is_integer(iat) and abs(iat - System.os_time(:second)) <= 5

      {:ECPrivateKey, _version, _private, parameters, public, _attributes} = ctx.config.apns.key
      der = :public_key.der_encode(:"ECDSA-Sig-Value", {:"ECDSA-Sig-Value", r, s})
      assert :public_key.verify(input, :sha256, der, {{:ECPoint, public}, parameters})
    end

    test "a sandbox key posts to the sandbox origin", ctx do
      {push_key, key} = Fixtures.push_key(ctx.config, environment: :sandbox)

      assert {:respond, 204, :empty, nil} =
               Poke.handle(Fixtures.poke(push_key, ctx.install), ctx.config)

      assert [request] = FakeProvider.requests()
      assert request.url == "https://api.sandbox.push.apple.com/3/device/" <> key.token
    end

    test "BadDeviceToken answers 410 without a second send", ctx do
      FakeProvider.script([{@apns, 400, [], ~s({"reason":"BadDeviceToken"})}])
      assert {:respond, 410, :unregistered, nil} = poke(ctx.config, ctx.install, provider: :apns)
      assert length(FakeProvider.requests()) == 1
    end

    test "an expired provider token is replaced and the send retried once", ctx do
      FakeProvider.script([{@apns, 403, [], ~s({"reason":"ExpiredProviderToken"})}])
      assert {:respond, 204, :empty, nil} = poke(ctx.config, ctx.install, provider: :apns)
      assert [first, second] = FakeProvider.requests()
      assert authorization(first) != authorization(second)
    end
  end

  describe "FCM" do
    test "the OAuth assertion is an RS256 JWT for the messaging scope under the service key",
         ctx do
      assert {:respond, 204, :empty, nil} = poke(ctx.config, ctx.install, provider: :fcm)
      assert [oauth, _send] = FakeProvider.requests()
      %{"assertion" => assertion} = URI.decode_query(oauth.body)

      {header, claims, input, signature} = jwt_parts(assertion)
      assert header == %{"alg" => "RS256", "typ" => "JWT"}

      assert %{
               "iss" => "relay@overalls-test.iam.example",
               "scope" => "https://www.googleapis.com/auth/firebase.messaging",
               "aud" => "https://oauth2.googleapis.com/token",
               "iat" => iat,
               "exp" => exp
             } = claims

      assert exp - iat == 3600

      {:RSAPrivateKey, _version, modulus, exponent, _d, _p, _q, _e1, _e2, _c, _other} =
        ctx.config.fcm.private_key

      assert :public_key.verify(input, :sha256, signature, {:RSAPublicKey, modulus, exponent})
    end

    for {status, body} <- [
          {404, ~s({"error":{"status":"NOT_FOUND"}})},
          {400, ~s({"error":{"details":[{"errorCode":"UNREGISTERED"}]}})},
          {403, ~s({"error":{"details":[{"errorCode":"SENDER_ID_MISMATCH"}]}})}
        ] do
      test "an FCM #{status} for a dead registration answers 410", ctx do
        FakeProvider.script([{@fcm, unquote(status), [], unquote(body)}])
        assert {:respond, 410, :unregistered, nil} = poke(ctx.config, ctx.install, provider: :fcm)
        assert [_oauth, _send] = FakeProvider.requests()
      end
    end

    test "a 401 drops the access token, exchanges again and resends once", ctx do
      FakeProvider.script([{@fcm, 401, [], ""}])
      assert {:respond, 204, :empty, nil} = poke(ctx.config, ctx.install, provider: :fcm)
      urls = Enum.map(FakeProvider.requests(), & &1.url)
      oauth = "https://oauth2.googleapis.com/token"
      send = @fcm <> "/v1/projects/overalls-test/messages:send"
      assert urls == [oauth, send, oauth, send]
    end
  end

  describe "WNS" do
    test "a 404 for a gone channel answers 410", ctx do
      FakeProvider.script([{@wns, 404, [], ""}])
      assert {:respond, 410, :unregistered, nil} = poke(ctx.config, ctx.install, provider: :wns)
    end

    test "a 401 drops the Entra token, exchanges again and resends once", ctx do
      FakeProvider.script([{@wns, 401, [], ""}])
      assert {:respond, 204, :empty, nil} = poke(ctx.config, ctx.install, provider: :wns)

      assert [
               "https://login.microsoftonline.com/" <> _,
               @wns <> _,
               "https://login.microsoftonline.com/" <> _,
               @wns <> _
             ] = Enum.map(FakeProvider.requests(), & &1.url)
    end
  end
end
