Code.require_file("../../../scripts/pins.ex", __DIR__)

defmodule Overalls.PinsTest do
  use ExUnit.Case, async: true
  import Hegel
  import Hegel.Gen
  alias Overalls.Pins

  @sri "sha256-pRGOQSClnXNI2iLUG6DYpsGvYcuw0drOutVZFTJNw90="
  @hex "612b2c0cc1bc413a6cb8c38fd611794caf0f2b436c50013d8b3794db12ad7354"

  @inline [
    ~s(  hash = "#{@sri}";),
    ~s(    sha256 = "#{@hex}";),
    ~s(  vendorHash = "#{@sri}";),
    ~s(  outputHash = "#{@sri}";)
  ]

  @clean [
    ~s(  hash = (import ../pins.nix\).ghSource;),
    ~s(  # hash = "#{@sri}";),
    ~s(  name = "plain";),
    ""
  ]

  # @cc [owner:ghuntley,label:verification;security] pin-registry-oracle
  # Any fixed-output attribute assigned a hash literal outside the exemptions
  # MUST be reported at its line; registry reads and comments MUST NOT be.
  property "reports exactly the inline hash assignments" do
    lines =
      draw("lines", list_of(one_of([member_of(@inline), member_of(@clean)]), max_length: 20))

    expected =
      for {line, number} <- Enum.with_index(lines, 1), line in @inline, do: number

    found =
      for {:inline, "a.nix", number, _} <- Pins.inline([{"a.nix", Enum.join(lines, "\n")}]),
          do: number

    assert found == expected
  end

  test "exempt sealed outputs are not reported" do
    path = "nix/domains/artifacts/guest/windows/published.nix"
    assert Pins.inline([{path, ~s(  narHash = "#{@sri}";)}]) == []
  end

  test "stale and unknown registry keys are reported" do
    files = [{"x.nix", "hash = (import ./pins.nix).used;\nother = (import ./pins.nix).missing;"}]

    assert Pins.registry_use(%{"used" => @sri, "stale" => @sri}, files) == [
             {:unused, "stale"},
             {:unknown, "x.nix", 2, "missing"}
           ]
  end

  test "the repository satisfies the registry rule" do
    assert Pins.check(Path.expand("../../..", __DIR__)) == []
  end
end
