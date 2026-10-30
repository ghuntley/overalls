defmodule Lilly.Lifecycle.ImageTemplateTest do
  use ExUnit.Case, async: true
  import Hegel
  import Hegel.Gen
  alias Lilly.Host.Lock
  alias Lilly.Lifecycle.{ImageTemplate, Journal}
  @moduletag :tmp_dir
  @moduletag capture_log: true
  @type model :: %{
          payload: map(),
          verified: boolean(),
          sealed: boolean(),
          retired: boolean(),
          gone: boolean()
        }

  property "template charge includes the manifest at maximum supported artifact sizes" do
    manifest_bytes = draw("manifest_bytes", integer(1..16384))
    artifact_bytes = 128 * 1024 ** 3 + 2 * 8 * 1024 ** 3

    assert ImageTemplate.valid_payload?(
             Map.put(payload(), "bytes", artifact_bytes + manifest_bytes)
           )

    refute ImageTemplate.valid_payload?(Map.put(payload(), "bytes", artifact_bytes + 16_385))
  end

  test "native firmware identities include the firmware and complete disk" do
    identities =
      Map.new(
        ~w(manifest.json firmware disk.raw),
        &{&1, [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11]}
      )

    assert ImageTemplate.valid_payload?(Map.put(payload(), "identities", identities))
  end

  # The 2026-10-16 template outage: a sealed FreeBSD template written before its
  # kernel `rootfs.ufs` kind was removed made the whole catalog unreadable.
  test "a record of a retired image kind stays decodable so it can be retired" do
    legacy = Map.new(~w(manifest.json kernel rootfs.ufs), &{&1, Enum.to_list(1..11)})

    for state <- ~w(ready quarantined retiring deleted) do
      assert ImageTemplate.valid_payload?(
               payload()
               |> Map.merge(%{"state" => state, "guid" => "42", "identities" => legacy})
             )
    end
  end

  property "identities name manifest.json and only single safe path components" do
    unsafe = member_of(["../kernel", "a/b", ".hidden", "", "Kernel", String.duplicate("a", 65)])
    names = ~w(manifest.json kernel initrd rootfs.ext4)

    name = draw("name", unsafe)
    size = draw("size", integer(2..3))
    safe = Map.new(Enum.take(names, size), &{&1, Enum.to_list(1..11)})
    assert ImageTemplate.valid_payload?(Map.put(payload(), "identities", safe))

    refute ImageTemplate.valid_payload?(
             Map.put(payload(), "identities", Map.put(safe, name, Enum.to_list(1..11)))
           )

    without_manifest = Map.new(tl(names), &{&1, Enum.to_list(1..11)})
    refute ImageTemplate.valid_payload?(Map.put(payload(), "identities", without_manifest))
  end

  # @cc [owner:ghuntley,label:verification] template-history-independent-facts
  # Generated histories MUST track prerequisite evidence independently from the
  # production graph, reopen durable state after every operation and preserve
  # state and revision on refusal. Replays MUST NOT change either.
  @tag :hegel
  # The full 100-case budget measured 14-26 s under the parallel suite on
  # 8 local CPUs; the slower CI runner exceeded the 60 s default.
  @tag timeout: 180_000
  test "publication and retirement require evidence; bindings and tombstones survive reopen", c do
    Hegel.check(
      fn ->
        commands =
          draw(
            "commands",
            list_of(
              member_of([
                :verify,
                :seal,
                :publish,
                :quarantine,
                :retire,
                :delete,
                :replace_guid,
                :replace_identity,
                :replay
              ]),
              min_length: 1,
              max_length: 25
            )
          )

        directory = Path.join(c.tmp_dir, Lilly.UUID.generate())
        payload = payload()

        locked(directory, fn ->
          assert :ok = Journal.write(ImageTemplate, directory, "template.json", payload)
        end)

        initial = %{payload: payload, verified: false, sealed: false, retired: false, gone: false}

        Enum.reduce(commands, initial, fn command, model ->
          {allowed, next, facts} = step(command, model)
          {:ok, before} = Journal.load(ImageTemplate, directory, "template.json")

          result =
            locked(directory, fn ->
              Journal.write(ImageTemplate, directory, "template.json", next)
            end)

          assert result == :ok == allowed
          {:ok, after_record} = Journal.load(ImageTemplate, directory, "template.json")

          if allowed and next != model.payload do
            assert after_record.revision == before.revision + 1
            assert after_record.payload == next
          else
            assert after_record == before
          end

          if allowed, do: %{facts | payload: next}, else: model
        end)
      end,
      test_cases: 100
    )
  end

  @spec step(atom(), model()) :: {boolean(), map(), model()}
  defp step(command, model) do
    state = model.payload["state"]

    {allowed, attrs, facts} =
      case command do
        :verify ->
          {state == "staging", %{"state" => "verifying", "guid" => "123"}, model}

        :seal ->
          {state == "verifying", %{"state" => "sealing", "identities" => identities()},
           %{model | verified: true}}

        :publish ->
          {model.verified and state == "sealing", %{"state" => "ready"}, %{model | sealed: true}}

        :quarantine ->
          {state in ~w(staging verifying sealing ready), %{"state" => "quarantined"}, model}

        :retire ->
          {not model.retired and not model.gone, %{"state" => "retiring"},
           %{model | retired: true}}

        :delete ->
          {model.retired and not model.gone, %{"state" => "deleted"}, %{model | gone: true}}

        :replace_guid ->
          {false, %{"guid" => "456"}, model}

        :replace_identity ->
          {false, %{"identities" => identities()}, model}

        :replay ->
          {true, %{}, model}
      end

    next = Map.merge(model.payload, attrs)
    {allowed or next == model.payload, next, facts}
  end

  defp payload do
    %{
      "state" => "staging",
      "host_id" => Lilly.UUID.generate(),
      "pool_id" => Lilly.UUID.generate(),
      "image_id" => "sha256:" <> String.duplicate("a", 64),
      "incarnation" => Lilly.UUID.generate(),
      "nonce" => String.duplicate("b", 64),
      "guid" => nil,
      "bytes" => 4096,
      "identities" => %{}
    }
  end

  defp identities,
    do:
      Map.new(
        ~w(manifest.json kernel initrd rootfs.ext4),
        &{&1, [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11]}
      )

  defp locked(directory, fun) do
    {:ok, lock} = Lock.acquire(directory)

    try do
      fun.()
    after
      Lock.release(lock)
    end
  end
end
