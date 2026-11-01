"""A failed Mix suite MUST fail every build, never a cached success (ADR-0269 M6).

Builds buck/tests/mix_failing's deliberately failing suite twice on one daemon
in its own isolation directory. Both builds must fail, each printing the
suite's marker with a different per-run nonce: an identical nonce means the
second build replayed a recorded log instead of running the suite. Before the fix the run action succeeded and recorded the
failure, so a shared action cache would have served it as a result.

Contract mix-test-cacheable-result: see buck/CONTRACTS. Needs unprivileged user
namespaces, as every Mix action does.
"""

from __future__ import annotations

import re
import subprocess
import sys
from pathlib import Path

BUCK2 = Path(".buck-cells/bin/buck2")
ISOLATION = "--isolation-dir=mix-test-failure-test"
TARGET = "//buck/tests/mix_failing:test"
MARKER = re.compile(r"mix_failing_fixture: deliberate failure run=([0-9-]+)")
# The test's environment has no Namespace token, while the checkout's
# untracked include (tools/buck2, ADR-0276) names $NAMESPACE_RBE_TOKEN in its
# headers: without these overrides the nested daemon retries the remote
# connection for about 45 s before building locally. The suite runs locally
# anyway.
NO_REMOTE = [
    "-c",
    "buck2_re_client.engine_address=",
    "-c",
    "buck2_re_client.action_cache_address=",
    "-c",
    "buck2_re_client.cas_address=",
    "-c",
    "buck2_re_client.http_headers=",
]
CONFIG = ["-c", "mix_failing.enabled=true", *NO_REMOTE]


def build(target: str) -> subprocess.CompletedProcess[str]:
    """One build of target on this test's daemon."""
    return subprocess.run(
        [str(BUCK2), ISOLATION, "build", "--console=simple", *CONFIG, target],
        capture_output=True,
        text=True,
        check=False,
    )


def main() -> int:
    runs: list[str] = []
    try:
        for attempt in (1, 2):
            run = build(TARGET)
            output = run.stdout + run.stderr
            if run.returncode == 0:
                print(
                    f"mix_test_failure_uncached: build {attempt} of a failing suite passed",
                    file=sys.stderr,
                )
                return 1
            found = MARKER.search(output)
            if found is None:
                print(
                    f"mix_test_failure_uncached: build {attempt} failed without running the suite:\n{output[-4000:]}",
                    file=sys.stderr,
                )
                return 1
            runs.append(found.group(1))
        if runs[0] == runs[1]:
            print(f"mix_test_failure_uncached: build 2 replayed run {runs[0]}", file=sys.stderr)
            return 1
        result = build(TARGET + "[test_result]")
        if result.returncode == 0:
            print(
                "mix_test_failure_uncached: [test_result] built for a failed suite", file=sys.stderr
            )
            return 1
    finally:
        subprocess.run([str(BUCK2), ISOLATION, "kill"], capture_output=True, check=False)
    print("mix_test_failure_uncached: the failing suite failed every build")
    return 0


if __name__ == "__main__":
    sys.exit(main())
