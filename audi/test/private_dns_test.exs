defmodule Audi.PrivateDNSTest do
  use ExUnit.Case, async: true
  import Hegel
  import Hegel.Gen
  import Bitwise
  alias Audi.DNS.Wire

  test "real UDP and TCP listeners serve the same private address" do
    server =
      start_supervised!({Audi.DNS.Server, authority_module: Audi.Private.DNS, authority: nil})

    port = Audi.DNS.Server.port(server)
    packet = question(["llm", "internal"], 1)
    {:ok, udp} = :gen_udp.open(0, [:binary, active: false])
    on_exit(fn -> :gen_udp.close(udp) end)
    :ok = :gen_udp.send(udp, {127, 0, 0, 1}, port, packet)
    assert {:ok, {_, ^port, response}} = :gen_udp.recv(udp, 0, 1000)
    assert <<7::16, flags::16, 1::16, 1::16, _::binary>> = response
    assert (flags &&& 0x0480) == 0x0400
    assert String.ends_with?(response, <<169, 254, 254, 1>>)
    {:ok, tcp} = :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, active: false, packet: 2])
    on_exit(fn -> :gen_tcp.close(tcp) end)
    :ok = :gen_tcp.send(tcp, packet)
    assert {:ok, ^response} = :gen_tcp.recv(tcp, 0, 1000)

    assert <<7::16, _::16, 1::16, 1::16, _::binary>> =
             Audi.Private.DNS.answer(question(["ssh", "integration", "internal"], 1), nil, :udp)

    assert <<7::16, _::16, 1::16, 1::16, _::binary>> =
             Audi.Private.DNS.answer(question(["otel", "integration", "internal"], 1), nil, :udp)

    # An IPv6 miss must not claim the existing integration name is absent;
    # a resolver may query AAAA before A and cache name-wide NXDOMAIN.
    for {type, answers, authorities} <- [{28, 0, 1}, {1, 1, 0}] do
      query = question(["com-github", "integration", "internal"], type)
      :ok = :gen_udp.send(udp, {127, 0, 0, 1}, port, query)
      assert {:ok, {_, ^port, reply}} = :gen_udp.recv(udp, 0, 1000)
      assert <<7::16, flags::16, 1::16, ^answers::16, ^authorities::16, _::binary>> = reply
      assert (flags &&& 0x40F) == 0x400
      :ok = :gen_tcp.send(tcp, query)
      assert {:ok, ^reply} = :gen_tcp.recv(tcp, 0, 1000)
    end
  end

  test "AAAA is authoritative NODATA; external names and transfers are refused" do
    for {labels, type, code, aa} <- [
          {["llm", "internal"], 28, 0, 0x400},
          {["com-github", "integration", "internal"], 28, 0, 0x400},
          {["ssh", "integration", "internal"], 28, 0, 0x400},
          {["-bad", "integration", "internal"], 28, 3, 0x400},
          {["a", "b", "integration", "internal"], 28, 3, 0x400},
          {["com-github", "integration", "example"], 28, 5, 0},
          {["llm", "example"], 1, 5, 0},
          {["internal"], 252, 5, 0}
        ] do
      assert <<7::16, flags::16, 1::16, 0::16, _::binary>> =
               Audi.Private.DNS.answer(question(labels, type), nil, :udp)

      assert (flags &&& 15) == code
      assert (flags &&& 0x400) == aa
    end
  end

  property "unknown internal names never resolve or fall back" do
    label = draw("label", string(:alphanumeric, min_length: 1, max_length: 63))
    assume(label != "llm")

    assert <<7::16, flags::16, 1::16, 0::16, _::binary>> =
             Audi.Private.DNS.answer(question([label, "internal"], 1), nil, :udp)

    assert (flags &&& 0x40F) == 0x403
  end

  test "the integration zone answers single labels and nothing deeper" do
    for {labels, code, answers} <- [
          {["esample", "integration", "internal"], 0, 1},
          {["a", "integration", "internal"], 0, 1},
          {["mirror-1", "integration", "internal"], 0, 1},
          {["a", "b", "integration", "internal"], 3, 0},
          {["integration", "internal"], 0, 0},
          {["a", "integration", "example"], 5, 0}
        ] do
      assert <<7::16, flags::16, 1::16, count::16, _::binary>> =
               Audi.Private.DNS.answer(question(labels, 1), nil, :udp)

      assert (flags &&& 0xF) == code
      assert count == answers
    end
  end

  property "integration labels answer from a closed lowercase charset only" do
    label = draw("label", string(:alphanumeric, min_length: 1, max_length: 40))
    upper? = draw("upper?", boolean())
    # The wire decoder canonicalizes labels to lowercase, so queries behave
    # case-insensitively; character validity is checked on the lowercased form.
    label = label |> String.downcase() |> then(&if(upper?, do: String.upcase(&1), else: &1))

    valid =
      label
      |> String.downcase()
      |> then(&Regex.match?(~r/\A[a-z][a-z0-9-]{0,38}[a-z0-9]\z|\A[a-z]\z/, &1))

    for type <- [28, 1] do
      packet =
        Audi.Private.DNS.answer(question([label, "integration", "internal"], type), nil, :udp)

      assert <<7::16, flags::16, 1::16, answers::16, _::binary>> = packet
      assert (flags &&& 0x400) == 0x400

      if valid and String.downcase(label) != "integration" do
        assert (flags &&& 0xF) == 0
        assert answers == if(type == 1, do: 1, else: 0)
      else
        assert (flags &&& 0xF) == 3
        assert answers == 0
      end
    end
  end

  @spec question([String.t()], non_neg_integer()) :: binary()
  defp question(labels, type),
    do: <<7::16, 0x100::16, 1::16, 0::48>> <> Wire.encode_name(labels) <> <<type::16, 1::16>>
end
