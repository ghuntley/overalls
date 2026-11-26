defmodule Marshall.Ingress.FleetACMETest do
  use ExUnit.Case, async: true
  import Hegel
  import Hegel.Gen
  alias Marshall.Ingress.ACME.{AccountKey, Request}
  alias Marshall.Ingress.FleetACMEConfig

  test "CSR recovery preserves the same wildcard key and exact DER" do
    assert {:ok, request} = Request.generate("apps.example.test")

    assert {:ok, restored} =
             Request.restore("apps.example.test", request.der, request.private_key_pem)

    assert restored.der == request.der
    assert restored.private_key_pem == request.private_key_pem

    assert {:error, :invalid_certificate_request} =
             Request.restore("other.example.test", request.der, request.private_key_pem)
  end

  property "account identity is derived from the saved scalar", test_cases: 100 do
    bytes = draw("bytes", binary(length: 32))

    case AccountKey.from_private(bytes) do
      {:ok, key} ->
        assert {:ok, recovered} = AccountKey.from_private(key.private)
        assert recovered.thumbprint == key.thumbprint
        refute inspect(key) =~ Base.encode16(bytes, case: :lower)

      {:error, :invalid_account_key} ->
        :ok
    end
  end

  test "issuer is disabled when unselected and rejects partial selection" do
    assert {:ok, nil} = FleetACMEConfig.from_env(%{})

    assert {:error, :invalid_configuration} =
             FleetACMEConfig.from_env(%{
               "MARSHALL_FLEET_ACME_DIRECTORY" => "https://ca.example.test/dir"
             })
  end

  # ADR-0285: a single-host deployment's own Audi replica is enough; the bound
  # stays one to eight distinct peers.
  @tag :tmp_dir
  property "issuer accepts one to eight distinct DNS peers", %{tmp_dir: dir}, test_cases: 50 do
    ca = Path.join(dir, "ca.pem")
    roots = Path.join(dir, "roots.pem")
    File.write!(ca, "ca")
    File.write!(roots, "roots")
    count = draw("count", integer(0..10))
    peers = for index <- 1..count//1, do: %{"address" => "192.0.2.#{index}", "port" => 53}

    env = fn nameservers ->
      %{
        "MARSHALL_FLEET_ACME_DIRECTORY" => "https://ca.example.test/dir",
        "MARSHALL_INGRESS_ZONE" => "apps.example.test",
        "MARSHALL_FLEET_ACME_ISSUER_CA_FILE" => ca,
        "MARSHALL_FLEET_ACME_ROOTS_FILE" => roots,
        "MARSHALL_FLEET_ACME_NAMESERVERS" => JSON.encode!(nameservers),
        "MARSHALL_FLEET_ACME_ACCEPT_TERMS" => "true"
      }
    end

    if count in 1..8 do
      assert {:ok, %{nameservers: parsed}} = FleetACMEConfig.from_env(env.(peers))
      assert length(parsed) == count
    else
      assert {:error, :invalid_configuration} = FleetACMEConfig.from_env(env.(peers))
    end

    if count >= 1 do
      assert {:error, :invalid_configuration} =
               FleetACMEConfig.from_env(env.(peers ++ [hd(peers)]))
    end
  end
end
