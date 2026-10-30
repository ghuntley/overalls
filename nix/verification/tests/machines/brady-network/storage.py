# @cc [owner:ghuntley,label:verification] brady-native-storage-proof
# Exercise the production preparation/observation helper against real ZFS, then
# use HTTP/TLS results, files and counters to prove cache publication and recovery.
# This fixture does not provide the Lilly actor/Firecracker attribution proof.
with subtest("cache recovers onto a separate native ZFS dataset"):
    router.succeed(
        "zpool create -f -O compression=lz4 -O mountpoint=/tank tank mirror /dev/vdb /dev/vdc",
        "zfs create -o mountpoint=/pool -o quota=2G tank/lilly",
    )
    brady_storage = dict(
        host_id="11111111-1111-4111-8111-111111111111",
        dataset="tank/brady",
        zfs="/run/current-system/sw/bin/zfs",
        zpool="/run/current-system/sw/bin/zpool",
        pool=dict(
            storage=dict(
                dataset="tank/lilly",
                dataset_guid=router.succeed("zfs get -Hpo value guid tank/lilly").strip(),
                zpool_guid=router.succeed("zpool get -Hpo value guid tank").strip(),
            )
        ),
    )
    router.succeed(
        "printf %s " + shlex.quote(json.dumps(brady_storage)) + " > /run/brady-storage.json",
        "python3 /etc/brady-storage.py /run/brady-storage.json",
        "systemctl start brady-pressure-test",
    )
    router.wait_until_succeeds(
        "jq -e '.gauges.cache_writable == 1' /run/brady/metrics.json", timeout=45
    )
    router.succeed(base + " http://origin.brady.test/public | grep -Fx isolated-brady-origin")
    router.wait_until_succeeds(
        "test $(find /var/cache/brady/objects -name body | wc -l) -eq 1", timeout=15
    )
    router.succeed("systemctl stop brady-origin-test")
    router.succeed(base + " http://origin.brady.test/public | grep -Fx isolated-brady-origin")
    router.succeed(
        base + " -H 'Range: bytes=0-7' http://origin.brady.test/public | grep -Fx isolated"
    )
    router.wait_until_succeeds(
        "jq -e '.counters.cache_hits >= 2' /run/brady/metrics.json", timeout=10
    )
    router.succeed("systemctl restart brady-network-test")
    router.wait_until_succeeds(
        base + " http://origin.brady.test/public | grep -Fx isolated-brady-origin", timeout=30
    )
    router.succeed("systemctl start brady-origin-test")
    router.wait_until_succeeds("ip netns exec origin ss -lnt | grep :80", timeout=15)
with subtest("secrets bypass storage and quota policy remains disposable"):
    for request in [
        "-H 'Authorization: Bearer synthetic-private' http://origin.brady.test/auth",
        "-H 'Cookie: synthetic-private' http://origin.brady.test/cookie",
        "'http://origin.brady.test/signed?token=synthetic-private'",
    ]:
        router.succeed(base + " " + request + " | grep -Fx isolated-brady-origin")
    assert router.succeed("find /var/cache/brady/objects -name body | wc -l").strip() == "1"
    assert router.succeed("zfs get -Hpo value reservation,refreservation tank/brady").split() == [
        "0",
        "0",
    ]
    assert router.succeed("zfs list -H -t snapshot -o name -r tank/brady").strip() == ""
    parent_guid = router.succeed("zfs get -Hpo value guid tank/lilly")
with subtest("stale pressure disables cache while proxy remains available"):
    router.succeed("systemctl stop brady-pressure-test")
    pressure_stopped_at = int(router.succeed("date +%s").strip())
    router.wait_until_succeeds(
        f"jq -e '.sampled_at >= {pressure_stopped_at + 5} and (.gauges.cache_writable == null or .gauges.cache_writable == 0)' /run/brady/metrics.json",
        timeout=20,
    )
    router.succeed(base + " http://origin.brady.test/pressure | grep -Fx isolated-brady-origin")
    assert router.succeed("find /var/cache/brady/objects -name body | wc -l").strip() == "1"
    router.succeed("systemctl start brady-pressure-test")
    router.wait_until_succeeds(
        "jq -e '.gauges.cache_writable == 1' /run/brady/metrics.json", timeout=30
    )
    assert router.succeed("zfs get -Hpo value guid tank/lilly") == parent_guid

with subtest("native quota shrink changes object admission without interrupting streaming"):
    original_quota = int(router.succeed("zfs get -Hpo value quota tank/brady").strip())
    router.succeed("zfs set quota=1048576 refquota=1048576 tank/brady")
    router.wait_until_succeeds(
        "jq -e '.cache_quota_bytes == 1048576' /run/brady-pressure/pressure.json", timeout=15
    )
    quota_changed_at = int(router.succeed("date +%s").strip())
    router.wait_until_succeeds(
        f"jq -e '.sampled_at >= {quota_changed_at + 3} and .gauges.cache_writable == 1' /run/brady/metrics.json",
        timeout=15,
    )
    router.succeed(
        base + " http://origin.brady.test/large -o /run/brady-large-body",
        "test $(stat -c %s /run/brady-large-body) -eq 200000",
    )
    assert router.succeed("find /var/cache/brady/objects -name body | wc -l").strip() == "1"
    router.succeed(f"zfs set quota={original_quota} refquota={original_quota} tank/brady")
    router.wait_until_succeeds(
        f"jq -e '.cache_quota_bytes == {original_quota}' /run/brady-pressure/pressure.json",
        timeout=15,
    )
    quota_restored_at = int(router.succeed("date +%s").strip())
    router.wait_until_succeeds(
        f"jq -e '.sampled_at >= {quota_restored_at + 3} and .gauges.cache_writable == 1' /run/brady/metrics.json",
        timeout=15,
    )
    router.succeed(base + " http://origin.brady.test/large -o /run/brady-large-body")
    router.wait_until_succeeds(
        "test $(find /var/cache/brady/objects -name body | wc -l) -eq 2", timeout=15
    )
    assert router.succeed("zfs get -Hpo value guid tank/lilly") == parent_guid
with subtest("guest-parent headroom stops cache writes without blocking requests"):
    router.succeed(
        "zfs set quota=10M tank/lilly",
        "dd if=/dev/urandom of=/pool/pressure bs=1M count=9 conv=fsync status=none",
    )
    pressure_changed_at = int(router.succeed("date +%s").strip())
    router.wait_until_succeeds(
        f"jq -e '.sampled_at >= {pressure_changed_at + 3} and .gauges.cache_writable == 0' /run/brady/metrics.json",
        timeout=20,
    )
    router.succeed(
        base + " http://origin.brady.test/parent-pressure | grep -Fx isolated-brady-origin"
    )
    # Native pressure evicts disposable objects as well as refusing new writes.
    assert router.succeed("find /var/cache/brady/objects -name body | wc -l").strip() == "0"
    router.succeed("rm /pool/pressure", "zfs set quota=2G tank/lilly", "zpool sync tank")
    router.wait_until_succeeds(
        "jq -e '.gauges.cache_writable == 1' /run/brady/metrics.json", timeout=20
    )
    assert router.succeed("zfs get -Hpo value guid tank/lilly") == parent_guid
    router.succeed(
        base + " http://origin.brady.test/parent-pressure | grep -Fx isolated-brady-origin"
    )
    router.wait_until_succeeds(
        "test $(find /var/cache/brady/objects -name body | wc -l) -eq 1", timeout=15
    )

with subtest("physical pool pressure retains the 15 to 20 percent hysteresis"):
    router.succeed("zfs create -o mountpoint=/pressure -o compression=off tank/pressure")
    pressure_before = json.loads(router.succeed("cat /run/brady-pressure/pressure.json"))
    mib = 1024 * 1024
    fill_mib = (
        pressure_before["pool_available_bytes"]
        - pressure_before["pool_total_bytes"] * 14 // 100
        + mib
        - 1
    ) // mib
    assert 0 < fill_mib < 4096
    router.succeed(
        f"dd if=/dev/urandom of=/pressure/fill bs=1M count={fill_mib} conv=fsync status=none",
        timeout=120,
    )
    router.succeed("zpool sync tank")
    router.wait_until_succeeds(
        "jq -e '.pool_available_bytes * 100 < .pool_total_bytes * 15' /run/brady-pressure/pressure.json",
        timeout=20,
    )
    pool_changed_at = int(router.succeed("date +%s").strip())
    router.wait_until_succeeds(
        f"jq -e '.sampled_at >= {pool_changed_at + 3} and .gauges.cache_writable == 0' /run/brady/metrics.json",
        timeout=20,
    )
    router.succeed(
        base + " http://origin.brady.test/pool-pressure | grep -Fx isolated-brady-origin"
    )
    assert router.succeed("find /var/cache/brady/objects -name body | wc -l").strip() == "0"
    retained_bytes = fill_mib * mib - pressure_before["pool_total_bytes"] * 4 // 100
    router.succeed(f"truncate -s {retained_bytes} /pressure/fill", "zpool sync tank")
    router.wait_until_succeeds(
        "jq -e '.pool_available_bytes * 100 > .pool_total_bytes * 17 and .pool_available_bytes * 100 < .pool_total_bytes * 19' /run/brady-pressure/pressure.json",
        timeout=20,
    )
    middle_at = int(router.succeed("date +%s").strip())
    router.wait_until_succeeds(
        f"jq -e '.sampled_at >= {middle_at + 3} and .gauges.cache_writable == 0' /run/brady/metrics.json",
        timeout=20,
    )
    router.succeed("rm /pressure/fill", "zpool sync tank")
    router.wait_until_succeeds(
        "jq -e '.pool_available_bytes * 100 > .pool_total_bytes * 20' /run/brady-pressure/pressure.json",
        timeout=20,
    )
    router.wait_until_succeeds(
        "jq -e '.gauges.cache_writable == 1' /run/brady/metrics.json", timeout=20
    )
    router.succeed(
        base + " http://origin.brady.test/pool-pressure | grep -Fx isolated-brady-origin"
    )
    router.wait_until_succeeds(
        "test $(find /var/cache/brady/objects -name body | wc -l) -eq 1", timeout=15
    )
    assert router.succeed("zfs get -Hpo value guid tank/lilly") == parent_guid

# @cc [owner:ghuntley,label:verification;security] brady-native-https-cache-recovery
# A complete HTTPS object MUST survive proxy restart and serve exact full/range
# bytes while its origin is stopped. A cached HTTP representation MUST NOT
# satisfy HTTPS. This proves native TLS/ZFS behavior, not guest boot trust.
with subtest("verified HTTPS cache serves full and range bytes after restart with origin stopped"):
    https = base + " --fail --cacert /run/brady-fixture/ca.pem"
    router.succeed(
        base + " --fail http://origin.brady.test/public | grep -Fx isolated-brady-origin"
    )
    router.wait_until_succeeds(
        "test $(find /var/cache/brady/objects -name body | wc -l) -eq 2", timeout=15
    )
    # The existing HTTP public object cannot authorize an HTTPS cache hit.
    before_https = int(router.succeed("find /var/cache/brady/objects -name body | wc -l"))
    assert router.succeed(https + " https://origin.brady.test/public") == "isolated-brady-origin\n"
    router.wait_until_succeeds(
        f"test $(find /var/cache/brady/objects -name body | wc -l) -eq {before_https + 1}",
        timeout=15,
    )
    router.succeed("systemctl stop brady-origin-test", "systemctl restart brady-network-test")
    router.wait_until_succeeds(
        https + " https://origin.brady.test/public | grep -Fx isolated-brady-origin",
        timeout=30,
    )
    assert router.succeed(https + " https://origin.brady.test/public") == "isolated-brady-origin\n"
    assert (
        router.succeed(https + " -H 'Range: bytes=0-7' https://origin.brady.test/public")
        == "isolated"
    )
    router.wait_until_succeeds(
        "jq -e '.counters.cache_hits >= 2' /run/brady/metrics.json", timeout=15
    )
    router.succeed("systemctl start brady-origin-test")
    router.wait_until_succeeds("ip netns exec origin ss -lnt | grep :443", timeout=15)
