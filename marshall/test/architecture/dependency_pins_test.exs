Code.require_file("../../../scripts/dependency_pins.ex", __DIR__)
Code.require_file("../../../scripts/cargo_security_upgrades.ex", __DIR__)

defmodule Overalls.DependencyPinsTest do
  use ExUnit.Case, async: true
  alias Overalls.{CargoSecurityUpgrades, DependencyPins}
  alias Overalls.DependencyPins.{Finding, HashMismatch}

  @targets %{
    "marshall" => %{
      locks: ["marshall/mix.lock"],
      hashes: %{"marshall" => "/nix/store/a.drv", "cedarCargo" => "/nix/store/b.drv"}
    },
    "lilly-native" => %{
      locks: ["lilly/native/hostd/Cargo.lock", "lilly/native/vm-watch/Cargo.lock"],
      hashes: %{}
    }
  }

  test "maps hash mismatches to their derivations" do
    log = """
    \e[31;1merror:\e[0m hash mismatch in fixed-output derivation '/nix/store/abc-overalls-galileo-deps-0.1.0.drv':
             specified: sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=
                got:    sha256-UISP3KF4eU9rGgFx+4CRVri3OPL3H454zokgV2faCME=
    """

    assert [
             %HashMismatch{
               drv_path: "/nix/store/abc-overalls-galileo-deps-0.1.0.drv",
               got: "sha256-UISP3KF4eU9rGgFx+4CRVri3OPL3H454zokgV2faCME="
             }
           ] =
             DependencyPins.parse_hash_mismatches(log)
  end

  test "replaces only the named hash keys and keeps the layout" do
    json = ~s({\n  "galileo": "sha256-old=",\n  "enrico": "sha256-old="\n}\n)

    assert {:ok, ~s({\n  "galileo": "sha256-new=",\n  "enrico": "sha256-old="\n}\n)} =
             DependencyPins.put_hashes(json, %{"galileo" => "sha256-new="})

    assert {:error, _} = DependencyPins.put_hashes(json, %{"missing" => "sha256-new="})
  end

  test "validates evaluated pin entries" do
    decoded = %{
      "marshall" => %{
        "locks" => ["marshall/mix.lock"],
        "hashes" => %{"marshall" => "/nix/store/a.drv"}
      }
    }

    assert {:ok, %{"marshall" => %{locks: ["marshall/mix.lock"]}}} =
             DependencyPins.targets(decoded)

    assert {:error, _} =
             DependencyPins.targets(%{"x" => %{"locks" => ["x"], "hashes" => %{"x" => 1}}})

    assert {:error, _} = DependencyPins.targets(%{"x" => %{"locks" => [], "hashes" => %{}}})
    assert {:error, _} = DependencyPins.targets([])
  end

  # @cc [owner:ghuntley,label:verification;build] dependency-pin-selection-oracle
  # A changed lock MUST select every pin entry that builds from it, and a lock
  # no entry builds from MUST be reported rather than silently skipped.
  test "selects affected entries and reports unregistered locks" do
    assert DependencyPins.affected(@targets, ["lilly/native/vm-watch/Cargo.lock"]) == [
             "lilly-native"
           ]

    assert DependencyPins.affected(@targets, ["protocol/mix.lock"]) == []

    assert DependencyPins.uncovered(@targets, ["marshall/mix.lock", "lyra/Cargo.lock"]) == [
             "lyra/Cargo.lock"
           ]
  end

  test "summarises findings, unresolved advisories and refreshed hashes" do
    finding = %Finding{
      kind: :advisory,
      package: "rustls",
      version: "0.23.45",
      id: "RUSTSEC-2026-0346",
      summary: "Debug leaks"
    }

    summary =
      DependencyPins.summary("RustSec", [{"lyra/Cargo.lock", [finding], [finding], true}], [
        "lyraVendor"
      ])

    assert summary =~ "lyra/Cargo.lock:\n- rustls 0.23.45: RUSTSEC-2026-0346 Debug leaks"
    assert summary =~ "Still vulnerable"
    assert summary =~ "Refreshed Nix dependency hashes: lyraVendor"

    assert DependencyPins.summary("RustSec", [{"a/Cargo.lock", [], [], false}], []) =~
             "No RustSec security findings in 1"
  end

  # Trimmed from cargo-audit 0.22.2 `--json` output for lyra/Cargo.lock.
  @cargo_audit ~S"""
  {"database": {}, "lockfile": {"dependency-count": 2},
   "vulnerabilities": {"found": true, "count": 2, "list": [
     {"advisory": {"id": "RUSTSEC-2023-0071", "package": "rsa", "title": "Marvin Attack: potential key recovery through timing sidechannels"},
      "versions": {"patched": [], "unaffected": []}, "package": {"name": "rsa", "version": "0.9.10"}},
     {"advisory": {"id": "RUSTSEC-2026-0346", "package": "rustls", "title": "`Debug` impls for client session values expose TLS secrets"},
      "versions": {"patched": [">=0.23.46"], "unaffected": []}, "package": {"name": "rustls", "version": "0.23.45"}}]},
   "warnings": {"unmaintained": [{"kind": "unmaintained", "package": {"name": "paste", "version": "1.0.15"}}]}}
  """

  test "parses cargo audit vulnerabilities and ignores informational warnings" do
    assert {:ok,
            [
              %Finding{package: "rsa", id: "RUSTSEC-2023-0071"},
              %Finding{package: "rustls", version: "0.23.45"}
            ] = findings} =
             CargoSecurityUpgrades.parse_audit(@cargo_audit)

    assert CargoSecurityUpgrades.update_specs(findings) == [
             "--package",
             "rsa@0.9.10",
             "--package",
             "rustls@0.23.45"
           ]

    assert {:ok, []} =
             CargoSecurityUpgrades.parse_audit(
               ~s({"vulnerabilities": {"found": false, "count": 0, "list": []}})
             )

    assert {:error, _} = CargoSecurityUpgrades.parse_audit("error: database fetch failed")
  end

  test "lists tracked Cargo.lock paths" do
    assert CargoSecurityUpgrades.lock_paths("lyra/Cargo.lock\0lilly/native/hostd/Cargo.lock\0") ==
             ["lilly/native/hostd/Cargo.lock", "lyra/Cargo.lock"]
  end

  test "only the root workspace Cargo.lock is accepted (ADR-0273)" do
    assert CargoSecurityUpgrades.single_root_lock(["Cargo.lock"]) == :ok

    assert CargoSecurityUpgrades.single_root_lock(["Cargo.lock", "lyra/Cargo.lock"]) ==
             {:error, ["lyra/Cargo.lock"]}

    assert CargoSecurityUpgrades.single_root_lock(["lyra/Cargo.lock"]) ==
             {:error, ["lyra/Cargo.lock"]}

    assert CargoSecurityUpgrades.single_root_lock([]) == {:error, []}
  end
end
