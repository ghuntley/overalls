import hashlib
import random
import time

# @cc [owner:ghuntley,label:verification] brady-large-native-proof
# Real packaged HTTPS/ZFS requests MUST match an independent streaming digest,
# require publication and hits, and retain exact bytes after origin loss/restart.
# Veth peers are native network fixtures, not Firecracker attribution evidence.
router.succeed(
    "zpool create -f -O compression=lz4 -O mountpoint=/tank tank mirror /dev/vdb /dev/vdc",
    "zfs create -o mountpoint=/pool -o quota=64G tank/lilly",
    "zfs create -o mountpoint=/clients -o quota=24G tank/clients",
)
large_storage = dict(
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
    "printf %s " + shlex.quote(json.dumps(large_storage)) + " > /run/brady-storage.json",
    "python3 /etc/brady-storage.py /run/brady-storage.json",
    "systemctl start brady-pressure-test",
)
router.wait_until_succeeds(
    "jq -e '.gauges.cache_writable == 1' /run/brady/metrics.json", timeout=45
)
large_curl = "/run/current-system/sw/bin/ip netns exec guest /run/current-system/sw/bin/curl --noproxy '*' -fsS --max-time 900 --cacert /run/brady-fixture/ca.pem"


# @cc [owner:ghuntley,label:verification;capacity] brady-large-host-space-reclaim
# Each subtest MUST start by trimming the pool, so blocks freed by earlier
# rewritten bodies, evicted cache objects and removed reader files return to
# the host (the vdevs use discard=unmap) before the next multi-gigabyte write.
# The trim MUST run between subtests, never during a measured write: with
# autotrim the pressure producer missed its three-second freshness window and
# the first 4 GiB publication was abandoned in both CI runs.
def reclaim_host_space() -> None:
    router.succeed("zpool trim -w tank", timeout=900)


def digest_segment(size: int, start: int = 0, length: int | None = None) -> str:
    remaining = size - start if length is None else length
    digest = hashlib.sha256()
    position = start
    while remaining:
        offset = position // 65536 * 65536
        seed = b"brady-large-" + size.to_bytes(8, "big") + offset.to_bytes(8, "big")
        block = hashlib.shake_256(seed).digest(min(65536, size - offset))
        take = min(remaining, len(block) - (position - offset))
        digest.update(block[position - offset : position - offset + take])
        position += take
        remaining -= take
    return digest.hexdigest()


def count_origins() -> int:
    return int(router.succeed("wc -l < /run/brady-fixture/origin-counts.jsonl").strip())


def rss() -> int:
    return (
        int(
            router.succeed(
                "pid=$(systemctl show brady-network-test -p MainPID --value); "
                "awk '/^VmRSS:/ {print $2}' /proc/$pid/status"
            ).strip()
        )
        * 1024
    )


baseline_rss = rss()
router.succeed("systemctl start brady-rss-test")
sizes = [
    4 * 1024**3 + 1,
    0,
    1,
    1024,
    1025,
    65535,
    65536,
    65537,
    1024**2,
    8 * 1024**2,
    32 * 1024**2,
    64 * 1024**2,
    128 * 1024**2,
    200 * 1024**2,
    256 * 1024**2,
    512 * 1024**2,
    1024**3,
    2 * 1024**3,
    2 * 1024**3 + 1,
    4 * 1024**3,
]
for kind in ("fixed", "chunked"):
    for size in sizes:
        with subtest(f"{kind} exact {size} bytes publish and reuse"):
            reclaim_host_space()
            before_objects = int(
                router.succeed("jq '.gauges.cache_objects' /run/brady/metrics.json")
            )
            url = f"https://origin.brady.test/stream/{kind}/{size}"
            router.succeed(large_curl + " " + url + " -o /clients/large-body", timeout=930)
            assert int(router.succeed("stat -c %s /clients/large-body")) == size
            expected = digest_segment(size)
            assert router.succeed("sha256sum /clients/large-body").split()[0] == expected
            # Receiving the last HTTP body byte precedes Store sync/rename.
            # Require actual publication before beginning the reuse window.
            try:
                router.wait_until_succeeds(
                    "jq -e '.gauges.cache_objects == "
                    + str(before_objects + 1)
                    + " and .gauges.cache_pending_bytes == 0 and .gauges.cache_writers == 0' "
                    + "/run/brady/metrics.json",
                    timeout=15,
                )
            except Exception:
                # Preserve bounded capacity evidence before the driver tears
                # down the VM; a complete response alone cannot prove custody.
                print(
                    router.succeed(
                        "cat /run/brady/metrics.json /run/brady-pressure/pressure.json; "
                        "cat /proc/uptime; "
                        "journalctl -u brady-pressure-test --no-pager -n 20"
                    )
                )
                raise
            origins = count_origins()
            for peer in ("guest", "guest2"):
                router.succeed(
                    large_curl.replace("exec guest ", "exec " + peer + " ")
                    + " "
                    + url
                    + " -o /clients/large-body",
                    timeout=930,
                )
                assert router.succeed("sha256sum /clients/large-body").split()[0] == expected
            observed_origins = count_origins()
            if observed_origins != origins:
                # Only closed fixture counters, capacity proof and probe unit
                # diagnostics are retained; no request/header payloads.
                fixture_state = router.succeed(
                    "cat /run/brady/metrics.json /run/brady-pressure/pressure.json; "
                    "cat /proc/uptime; "
                    "journalctl -u brady-pressure-test --no-pager -n 20"
                )
                raise AssertionError(
                    f"Expected {origins} origin requests, observed {observed_origins}; "
                    f"fixture pressure state: {fixture_state}"
                )
            assert rss() - baseline_rss < 128 * 1024**2

with subtest("stale pressure pauses writes without losing completed native reads"):
    reclaim_host_space()
    router.succeed("systemctl freeze brady-pressure-test")
    router.wait_until_succeeds(
        "jq -e '.gauges.cache_writable == 0' /run/brady/metrics.json", timeout=15
    )
    origins = count_origins()
    router.succeed(
        large_curl + " https://origin.brady.test/stream/chunked/4294967296 -o /clients/large-body"
    )
    assert router.succeed("sha256sum /clients/large-body").split()[0] == digest_segment(4 * 1024**3)
    assert count_origins() == origins
    for _ in range(2):
        router.succeed(
            large_curl + " https://origin.brady.test/stream/chunked/1048577 -o /clients/stale-body"
        )
        assert router.succeed("sha256sum /clients/stale-body").split()[0] == digest_segment(1048577)
    assert count_origins() == origins + 2
    router.succeed("systemctl thaw brady-pressure-test")
    router.wait_until_succeeds(
        "jq -e '.gauges.cache_writable == 1' /run/brady/metrics.json", timeout=15
    )

with subtest("public pinned GitHub-shape archive caches without explicit freshness or length"):
    reclaim_host_space()
    before_objects = int(router.succeed("jq '.gauges.cache_objects' /run/brady/metrics.json"))
    archive_url = "https://codeload.github.com/NixOS/nixpkgs/legacy.tar.gz/" + "a" * 40
    router.succeed(large_curl + " " + archive_url + " -o /clients/archive-body")
    assert router.succeed("sha256sum /clients/archive-body").split()[0] == digest_segment(
        8 * 1024**2
    )
    router.wait_until_succeeds(
        "jq -e '.gauges.cache_objects == "
        + str(before_objects + 1)
        + " and .gauges.cache_pending_bytes == 0 and .gauges.cache_writers == 0' "
        + "/run/brady/metrics.json",
        timeout=15,
    )
    origins = count_origins()
    router.succeed(
        large_curl.replace("exec guest ", "exec guest2 ")
        + " "
        + archive_url
        + " -o /clients/archive-body"
    )
    assert count_origins() == origins
    router.succeed(
        large_curl
        + " -H 'Authorization: Bearer synthetic-private' "
        + archive_url
        + " -o /dev/null"
    )
    assert count_origins() == origins + 1
    assert int(router.succeed("cat /run/brady-rss-peak")) - baseline_rss < 128 * 1024**2

# @cc [owner:ghuntley,label:verification;security] brady-native-archive-histories
# Canonical pinned archive histories MUST reuse only complete anonymous public
# bytes. Private/trailer/truncated responses MUST revisit the real TLS origin.
# Payload digests and expected origin counts MUST derive from workload inputs.
archive_random = random.Random(135)
archive_histories: list[tuple[int, int, str]] = [
    (0, 0, "tar.gz"),
    (0, 65537, "legacy.tar.gz"),
    (1, 65536, "tar.gz"),
    (2, 1, "legacy.tar.gz"),
    (3, 65537, "tar.gz"),
    (3, 1, "legacy.tar.gz"),
    (3, 65535, "tar.gz"),
    (3, 65536, "legacy.tar.gz"),
]
archive_histories.extend(
    (
        archive_random.randrange(4),
        archive_random.choice([1, 65535, 65536, 65537]),
        archive_random.choice(["tar.gz", "legacy.tar.gz"]),
    )
    for _ in range(7)
)
for history_index, (mode, size, form) in enumerate(archive_histories):
    with subtest(f"generated pinned archive {history_index} mode {mode} size {size}"):
        reclaim_host_space()
        revision = f"{mode:x}{size:08x}{history_index:031x}"
        archive_url = f"https://codeload.github.com/Property/fixture/{form}/{revision}"
        before_objects = int(router.succeed("jq '.gauges.cache_objects' /run/brady/metrics.json"))
        origins = count_origins()
        for client in ("guest", "guest2"):
            command = (
                large_curl.replace("exec guest ", f"exec {client} ")
                + " "
                + archive_url
                + " -o /clients/archive-history"
            )
            if mode == 3:
                router.fail(command)
            else:
                router.succeed(command)
                assert router.succeed("sha256sum /clients/archive-history").split()[
                    0
                ] == digest_segment(size)
                if mode == 0 and client == "guest":
                    router.wait_until_succeeds(
                        "jq -e '.gauges.cache_objects == "
                        + str(before_objects + 1)
                        + " and .gauges.cache_pending_bytes == 0 and .gauges.cache_writers == 0' "
                        + "/run/brady/metrics.json",
                        timeout=15,
                    )
        assert count_origins() == origins + (1 if mode == 0 else 2)

with subtest("large completed HTTPS representations survive proxy restart and origin loss"):
    reclaim_host_space()
    router.succeed(
        "systemctl stop brady-rss-test brady-origin-test", "systemctl restart brady-network-test"
    )
    for kind in ("fixed", "chunked"):
        size = 4 * 1024**3 + 1
        url = f"https://origin.brady.test/stream/{kind}/{size}"
        router.wait_until_succeeds(large_curl + " " + url + " -o /clients/large-body", timeout=930)
        assert router.succeed("sha256sum /clients/large-body").split()[0] == digest_segment(size)
        for start in (0, 2**31 - 7, 2**32 - 7):
            length = min(65536, size - start)
            router.succeed(
                large_curl
                + f" -H 'Range: bytes={start}-{start + length - 1}' "
                + url
                + " -o /clients/large-range"
            )
            assert int(router.succeed("stat -c %s /clients/large-range")) == length
            assert router.succeed("sha256sum /clients/large-range").split()[0] == digest_segment(
                size, start, length
            )
        router.succeed(large_curl + " -H 'Range: bytes=-65536' " + url + " -o /clients/large-range")
        assert router.succeed("sha256sum /clients/large-range").split()[0] == digest_segment(
            size, size - 65536, 65536
        )
    status = router.succeed(
        large_curl.replace("-fsS", "-sS")
        + " -H 'Range: bytes=0-0' https://origin.brady.test/stream/chunked/0 -o /dev/null -w '%{http_code}'"
    )
    assert status == "416"
    router.succeed("systemctl start brady-origin-test")
    router.wait_until_succeeds("ip netns exec origin ss -lnt | grep :443", timeout=15)

with subtest("four large reads and one slow reader do not stall a small cache hit"):
    reclaim_host_space()
    url = "https://origin.brady.test/stream/chunked/4294967296"
    origins = count_origins()
    for index in range(4):
        router.succeed(
            "systemd-run --quiet --unit=brady-large-reader-"
            + str(index)
            + " "
            + large_curl
            + " "
            + url
            + f" -o /clients/reader-{index}"
        )
    router.succeed(
        "systemd-run --quiet --unit=brady-slow-reader "
        + large_curl
        + " --limit-rate 64k "
        + url
        + " -o /dev/null"
    )
    peak = rss()
    for _ in range(8):
        started = time.monotonic()
        router.succeed(
            large_curl.replace("--max-time 900", "--max-time 3")
            + " https://origin.brady.test/stream/fixed/1 -o /dev/null"
        )
        assert time.monotonic() - started < 3
        peak = max(peak, rss())
        time.sleep(0.1)
    for index in range(4):
        router.wait_until_succeeds(
            f"test $(stat -c %s /clients/reader-{index}) -eq 4294967296", timeout=930
        )
        assert router.succeed(f"sha256sum /clients/reader-{index}").split()[0] == digest_segment(
            4 * 1024**3
        )
    router.succeed("systemctl stop brady-slow-reader")
    assert peak - baseline_rss < 5 * 128 * 1024**2
    assert count_origins() == origins
    router.succeed("rm " + " ".join(f"/clients/reader-{index}" for index in range(4)))

with subtest("incomplete and sensitive chunked bodies never publish"):
    reclaim_host_space()
    for kind in ("truncated", "trailer", "private"):
        before = count_origins()
        command = (
            large_curl
            + f" https://origin.brady.test/stream/{kind}/4294967297 -o /clients/refused-body"
        )
        for _ in range(2):
            if kind == "truncated":
                router.fail(command, timeout=930)
            else:
                router.succeed(command, timeout=930)
                assert router.succeed("sha256sum /clients/refused-body").split()[
                    0
                ] == digest_segment(4 * 1024**3 + 1)
        assert count_origins() == before + 2
    router.wait_until_succeeds(
        "jq -e '.gauges.cache_pending_bytes == 0' /run/brady/metrics.json", timeout=15
    )
    journal = router.succeed("journalctl -u brady-network-test -o cat --no-pager")
    assert '"cache_write":"published"' in journal
    assert '"cache":"hit"' in journal
    assert '"outcome":"abandoned"' in journal
    assert "synthetic-private" not in journal
    assert "origin.brady.test" not in journal

with subtest("native reduced quota bypasses chunked storage while full streaming survives"):
    reclaim_host_space()
    quota = int(router.succeed("zfs get -Hpo value quota tank/brady").strip())
    router.succeed(
        "zfs set quota=10M tank/lilly",
        "dd if=/dev/urandom of=/pool/pressure bs=1M count=9 conv=fsync status=none",
    )
    router.wait_until_succeeds(
        "jq -e '.gauges.cache_writable == 0 and .gauges.cache_used_bytes == 0' /run/brady/metrics.json",
        timeout=20,
    )
    router.succeed("rm /pool/pressure", "zfs set quota=64G tank/lilly", "zpool sync tank")
    router.succeed("zfs set quota=1048576 refquota=1048576 tank/brady")
    router.wait_until_succeeds(
        "jq -e '.cache_quota_bytes == 1048576' /run/brady-pressure/pressure.json", timeout=15
    )
    time.sleep(4)
    origins = count_origins()
    for _ in range(2):
        router.succeed(
            large_curl + " https://origin.brady.test/stream/chunked/2097152 -o /clients/quota-body"
        )
        assert router.succeed("sha256sum /clients/quota-body").split()[0] == digest_segment(
            2 * 1024**2
        )
    assert count_origins() == origins + 2
    router.wait_until_succeeds(
        "jq -e '.gauges.cache_pending_bytes == 0' /run/brady/metrics.json", timeout=15
    )
    router.succeed(f"zfs set quota={quota} refquota={quota} tank/brady")
