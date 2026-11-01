defmodule Lilly.Host.PoolSnapshotTest do
  @moduledoc """
  ADR-0152: one pool-locked snapshot replaces the per-command native reads of
  disk preparation. These properties compare the snapshot-derived checks with
  the targeted per-command checks they replace, over generated native trees.
  They establish the equivalence of the pure predicates only; native ZFS
  behavior remains the `image-template` and `zfs-guest-clone` machine tests.
  """
  use ExUnit.Case, async: true
  import Hegel
  import Hegel.Gen
  alias Lilly.Host.{ImageTemplate, Lock, Pool, PoolSnapshot, ZFS, ZFSDataset}
  @moduletag :tmp_dir

  @host "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
  @pool_id "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"
  @parent "tank/lilly"
  @ids for n <- 1..4, do: "cccccccc-cccc-4ccc-8ccc-" <> String.pad_leading("#{n}", 12, "0")
  @placements for n <- 1..2, do: "dddddddd-dddd-4ddd-8ddd-" <> String.pad_leading("#{n}", 12, "0")
  # Per-name weights from child/0's kind, ID and placement draws. VM has two
  # placement names, so kind weight 2 gives each VM name the weight 4 shared by
  # each template name; stray names retain weight 1.
  @child_identities for {kind, ids, weight} <- [
                          {:template, @ids, 4},
                          {:vm, @placements, 4},
                          {:stray, @ids, 1}
                        ],
                        id <- ids,
                        do: {weight, {kind, id}}

  @typep child_identity :: {:template | :vm | :stray, String.t()}

  @spec pool() :: Pool.t()
  defp pool do
    %Pool{
      id: @pool_id,
      path: "/pool",
      filesystem_id: "zfs:1:2",
      host_id: @host,
      storage: %{backend: :zfs, zpool_guid: "1", dataset_guid: "2", dataset: @parent},
      extents: []
    }
  end

  # ---- Generators: native trees with templates, VMs and strays ----

  @spec child(child_identity()) :: Hegel.Gen.t()
  defp child({kind, identity}) do
    # Biased toward rows the observation accepts, so accepted trees routinely
    # hold several artifacts; every refusal shape still occurs.
    gen all(
          id <- if(kind == :vm, do: member_of(@ids), else: constant(identity)),
          placement <- if(kind == :vm, do: constant(identity), else: member_of(@placements)),
          mount <-
            frequency([
              {6, constant(:canonical)},
              {3, constant(:claimed)},
              {1, constant(:foreign)}
            ]),
          readonly <- member_of(["on", "off"]),
          collide <- frequency([{9, constant(false)}, {1, constant(true)}]),
          used <- integer(0..1000),
          extra <-
            frequency([
              {12, constant(:none)},
              {1, constant(:snapshot)},
              {1, constant(:descendant)},
              {1, constant(:unmounted)}
            ])
        ) do
      prefix = %{template: "template-", vm: "vm-", stray: "scratch-"}[kind]
      name = @parent <> "/" <> prefix <> if(kind == :vm, do: placement, else: id)
      guid = if collide, do: "31", else: Integer.to_string(100 + :erlang.phash2(name, 1_000_000))

      directory =
        %{template: "templates", vm: "vms", stray: "scratch"}[kind]

      mountpoint =
        case mount do
          :canonical -> "/pool/#{directory}/#{if kind == :vm, do: placement, else: id}"
          :claimed -> "/pool/vms/" <> placement
          :foreign -> "/foreign/" <> id
        end

      readonly = if kind == :vm, do: "off", else: readonly

      row =
        row(name, mountpoint, guid, %{
          "used" => used,
          "usedbydataset" => used,
          "readonly" => readonly,
          "mounted" => if(extra == :unmounted, do: "no", else: "yes")
        })

      {name, row, extra}
    end
    |> map(fn {name, row, extra} -> {name, {row, extra}} end)
  end

  @spec children([{pos_integer(), child_identity()}], non_neg_integer()) ::
          Hegel.Gen.t()
  defp children(_available, 0), do: constant([])

  defp children(available, count) do
    # Select each name once rather than retrying duplicate draws from fourteen
    # names. These weights preserve the original name-level draw probabilities
    # (the two VM placements each receive the same per-name weight as the four
    # template IDs), renormalized over names that remain available.
    gen all(
          identity <-
            frequency(Enum.map(available, fn {weight, id} -> {weight, constant(id)} end)),
          child <- child(identity),
          rest <-
            children(
              Enum.reject(available, fn {_weight, id} -> id == identity end),
              count - 1
            )
        ) do
      [child | rest]
    end
  end

  @spec tree() :: Hegel.Gen.t()
  defp tree do
    gen all(
          count <- integer(0..6),
          children <- children(@child_identities, count)
        ) do
      rows =
        Enum.flat_map(children, fn {name, {row, extra}} ->
          case extra do
            :snapshot ->
              [{name, row}, {name <> "@x", snapshot_row(name <> "@x", "77")}]

            :descendant ->
              [{name, row}, {name <> "/nested", row(name <> "/nested", row["mountpoint"], "78")}]

            _ ->
              [{name, row}]
          end
        end)

      used =
        rows
        |> Enum.filter(&(&1 |> elem(0) |> direct_child?()))
        |> Enum.map(&elem(&1, 1)["used"])
        |> Enum.sum()

      parent =
        row(@parent, "/pool", "2", %{
          "used" => used + 5,
          "usedbychildren" => used,
          "usedbydataset" => 5,
          "available" => 100
        })

      Map.new([{@parent, parent} | rows])
    end
  end

  defp direct_child?(name),
    do:
      String.starts_with?(name, @parent <> "/") and
        not String.contains?(String.replace_prefix(name, @parent <> "/", ""), ["/", "@"])

  # The rows a targeted `zfs list -r -t all <name>` would return.
  defp subtree(tree, name),
    do:
      Map.filter(tree, fn {row, _} ->
        row == name or String.starts_with?(row, [name <> "@", name <> "#", name <> "/"])
      end)

  defp kind, do: constant(:template)

  # @cc [owner:ghuntley,label:verification;capacity] snapshot-shape-equals-targeted-read
  # Over every generated tree the pool-locked observation accepts, the snapshot
  # artifact check MUST equal the targeted per-command check it replaces, for
  # every name, GUID expectation, seal and artifact kind, including refusals.
  @tag :hegel
  test "snapshot-derived artifact shape equals the targeted per-command read" do
    identity = Pool.zfs_identity(pool())
    # Outcome tallies prove the generated space is not vacuous.
    tally = :counters.new(3, [])

    Hegel.check(
      fn test_case ->
        tree = :hegel.draw(test_case, "native tree", tree())

        probes =
          :hegel.draw(
            test_case,
            "artifact probes",
            list_of(
              tuple({
                member_of(
                  Map.keys(tree) ++
                    for(
                      id <- @ids,
                      prefix <- ~w(template- standby-),
                      do: @parent <> "/" <> prefix <> id
                    )
                ),
                member_of([nil, "31", "99" | Enum.map(Map.values(tree), & &1["guid"])]),
                member_of([:on, :off, :either]),
                kind()
              }),
              min_length: 1,
              max_length: 12
            )
          )

        case ZFS.accounting(tree, identity) do
          {:ok, observation} ->
            parents = Map.take(tree, [@parent])

            # Drawn probes rarely hit an accepted template's exact name, GUID
            # and seal together; seed 3204049527 drew none in 400 cases. Each
            # observed child is therefore also probed with no GUID expectation
            # and either seal, so every accepted template exercises acceptance.
            observed =
              for name <- Enum.sort(Map.keys(observation.children)),
                  do: {name, nil, :either, :template}

            for {name, guid, seal, kind} <- probes ++ observed do
              targeted =
                ZFS.artifact_rows(identity, parents, subtree(tree, name), name, guid, seal, kind)

              assert ZFS.observed_artifact(identity, observation.children, name, guid, seal, kind) ==
                       targeted

              :counters.add(tally, if(match?({:ok, _}, targeted), do: 1, else: 2), 1)
            end

          :error ->
            # An observation the accounting refuses withholds the whole pool, so
            # no snapshot-derived check can accept anything from it.
            :counters.add(tally, 3, 1)
        end
      end,
      test_cases: 400
    )

    assert :counters.get(tally, 1) > 0, "no generated probe was accepted"
    assert :counters.get(tally, 2) > 0, "no generated probe was refused"
    assert :counters.get(tally, 3) > 0, "no generated tree was refused by accounting"
  end

  # ---- Template audit: the snapshot join versus the per-template commands ----

  @states ~w(staging verifying sealing ready quarantined retiring deleted)

  @spec template_world() :: Hegel.Gen.t()
  defp template_world do
    gen all(
          entries <-
            tuple(
              Enum.map(@ids, fn id ->
                one_of([
                  constant(nil),
                  tuple({
                    constant(id),
                    member_of(@states),
                    member_of([:bound, :unbound]),
                    member_of([:present, :absent]),
                    member_of([:exact, :wrong_guid]),
                    member_of(["on", "off"]),
                    member_of([:match, :foreign_host, :wrong_nonce, :vm_tag, :missing])
                  })
                ])
              end)
            )
            |> map(fn entries -> entries |> Tuple.to_list() |> Enum.reject(&is_nil/1) end),
          stray <- member_of([nil | @ids])
        ) do
      records =
        for {id, state, bound, _, _, _, _} <- entries do
          %{
            state: String.to_atom(state),
            payload: %{
              "state" => state,
              "incarnation" => id,
              "nonce" => "n-" <> id,
              "guid" => if(bound == :bound, do: guid(id), else: nil)
            }
          }
        end

      native =
        for {id, _, _, :present, guid_mode, readonly, owner} <- entries do
          {id, if(guid_mode == :exact, do: guid(id), else: "9" <> String.slice(id, -1, 1)),
           readonly, owner}
        end

      native =
        if stray && not Enum.any?(entries, &(elem(&1, 0) == stray)),
          do: [{stray, guid(stray), "on", :match} | native],
          else: native

      {records, native}
    end
  end

  defp guid(id), do: "4" <> String.slice(id, -1, 1)

  defp template_tree(native) do
    rows =
      for {id, guid, readonly, _} <- native do
        name = @parent <> "/template-" <> id
        {name, row(name, "/pool/templates/" <> id, guid, %{"readonly" => readonly})}
      end

    Map.new([{@parent, row(@parent, "/pool", "2", %{"available" => 10})} | rows])
  end

  defp template_owners(native) do
    for {id, guid, _, owner} <- native, owner != :missing, into: %{} do
      tags =
        case owner do
          :match ->
            %{"host" => @host, "pool" => @pool_id, "vm" => "-", "nonce" => "n-" <> id}

          :foreign_host ->
            %{"host" => "foreign", "pool" => @pool_id, "vm" => "-", "nonce" => "n-" <> id}

          :wrong_nonce ->
            %{"host" => @host, "pool" => @pool_id, "vm" => "-", "nonce" => "other"}

          :vm_tag ->
            %{"host" => @host, "pool" => @pool_id, "vm" => hd(@placements), "nonce" => "n-" <> id}
        end

      {@parent <> "/template-" <> id, Map.put(tags, "guid", guid)}
    end
  end

  # The pre-ADR-0152 audit, expressed per template: the targeted
  # template_child read (its exec/setuid/devices seal held), the owner listing
  # re-read and matched, joined to the durable records exactly as before.
  defp per_command_audit(pool, records, tree, owners) do
    identity = Pool.zfs_identity(pool)

    children =
      Map.filter(tree, fn {name, _} -> String.starts_with?(name, @parent <> "/template-") end)

    known =
      for r <- records,
          r.state != :deleted,
          into: %{},
          do: {@parent <> "/template-" <> r.payload["incarnation"], r.payload}

    parents = Map.take(tree, [@parent])

    if Enum.all?(children, fn {name, row} ->
         value = known[name]
         seal = if value && value["state"] == "ready", do: :on, else: :either

         value && owner_matches?(owners[name], value) &&
           (is_nil(value["guid"]) or row["guid"] == value["guid"]) &&
           match?(
             {:ok, _},
             ZFS.artifact_rows(
               identity,
               parents,
               subtree(tree, name),
               name,
               value["guid"],
               seal,
               :template
             )
           )
       end) and
         Enum.all?(known, fn {name, value} ->
           Map.has_key?(children, name) or value["state"] in ~w(staging retiring)
         end),
       do: :ok,
       else: {:error, :template_unconfirmed}
  end

  defp owner_matches?(owner, value) when is_map(owner),
    do:
      owner["host"] == @host and owner["pool"] == @pool_id and owner["vm"] == "-" and
        owner["nonce"] == value["nonce"] and
        (is_nil(value["guid"]) or owner["guid"] == value["guid"])

  defp owner_matches?(_, _), do: false

  # @cc [owner:ghuntley,label:verification;capacity] template-audit-equals-per-command-audit
  # Over generated template records and native trees (sealed and unsealed,
  # bound and unbound, replaced GUIDs, foreign or missing owners, unknown and
  # missing children), the snapshot join MUST decide exactly as the
  # per-template native audit did whenever the template's execution seal held.
  @tag :hegel
  test "template audit from the snapshot equals the per-template native audit" do
    pool = pool()
    identity = Pool.zfs_identity(pool)

    tally = :counters.new(2, [])

    Hegel.check(
      fn test_case ->
        {records, native} = :hegel.draw(test_case, "template world", template_world())
        tree = template_tree(native)
        owners = template_owners(native)
        {:ok, observation} = ZFS.accounting(tree, identity)

        children =
          Map.filter(observation.children, fn {name, _} ->
            String.starts_with?(name, @parent <> "/template-")
          end)

        expected = per_command_audit(pool, records, tree, owners)
        assert ImageTemplate.audit_records(pool, records, children, owners) == expected
        :counters.add(tally, if(expected == :ok, do: 1, else: 2), 1)
      end,
      test_cases: 400
    )

    assert :counters.get(tally, 1) > 0, "no generated template world was accepted"
    assert :counters.get(tally, 2) > 0, "no generated template world was refused"
  end

  # ---- The snapshot never outlives its lock acquisition ----

  # @cc [owner:ghuntley,label:verification;concurrency] stale-snapshot-refused
  # A snapshot read under a lock that has since been released MUST be refused
  # by classification before any native effect.
  test "a snapshot outliving its lock is refused before classification or claim", %{tmp_dir: dir} do
    File.chmod!(dir, 0o700)
    {:ok, lock} = Lock.acquire(Path.join(dir, "pool-lock"))

    snapshot = %PoolSnapshot{
      lock: lock,
      observation: %{snapshots: %{}, children: %{}},
      owners: %{},
      mounts: []
    }

    pool = %{pool() | path: dir}
    assert PoolSnapshot.held?(snapshot)
    # Held: classification proceeds to its local checks (no claim index here).
    assert {:error, :active_claims} = ZFSDataset.classify_allocations(pool, snapshot)

    :ok = Lock.release(lock)
    refute PoolSnapshot.held?(snapshot)
    assert {:error, :pool_lock} = ZFSDataset.classify_allocations(pool, snapshot)

    refute PoolSnapshot.held?(:not_a_snapshot)
  end

  defp snapshot_row(name, guid) do
    absent = ZFS.properties() -- ~w(name type guid used compressratio)

    Map.merge(Map.new(absent, &{&1, "-"}), %{
      "name" => name,
      "type" => "snapshot",
      "guid" => guid,
      "used" => 0,
      "compressratio" => 1.0
    })
  end

  defp row(name, mount, guid, changes \\ %{}) do
    %{
      "name" => name,
      "type" => "filesystem",
      "guid" => guid,
      "mountpoint" => mount,
      "mounted" => "yes",
      "compression" => "lz4",
      "reservation" => 0,
      "refreservation" => 0,
      "dedup" => "off",
      "sync" => "standard",
      "origin" => "-",
      "used" => 0,
      "available" => 0,
      "logicalused" => 0,
      "quota" => 0,
      "compressratio" => 1.0,
      "usedbychildren" => 0,
      "usedbydataset" => 0,
      "usedbyrefreservation" => 0,
      "usedbysnapshots" => 0,
      "refquota" => 0,
      "readonly" => "off",
      "canmount" => "on"
    }
    |> Map.merge(changes)
  end
end
