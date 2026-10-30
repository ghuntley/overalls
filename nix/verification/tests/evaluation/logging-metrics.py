"""Exercise production numeric translation for catalogued events and refuse retired shapes."""

from __future__ import annotations

import copy
import json
import os
import re
import socket
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request
from pathlib import Path


def object_value(value: object) -> dict[str, object]:
    if not isinstance(value, dict) or not all(isinstance(key, str) for key in value):
        raise ValueError("invalid configuration")
    return value


def rows(value: object) -> list[dict[str, object]]:
    if not isinstance(value, list):
        raise ValueError("invalid configuration list")
    return [object_value(row) for row in value]


def emit(
    descriptor: dict[str, object],
    service: str,
    payload: dict[str, object],
    *,
    prometheus: bool = False,
    ready: tuple[bytes, ...] = (b"observed_at_seconds",),
    wait_seconds: float = 4.0,
) -> tuple[bytes, bytes, bytes]:
    """Run the real Fluent Bit translation with trusted synthetic journal origin.

    Each catalogued gauge has its own log_to_metrics emitter, so one scrape can
    expose some gauges before others. A positive caller names every gauge it
    asserts in ``ready`` and the scrape is retried until all are present or the
    deadline passes; refusal callers keep the short default observation window.
    """
    configuration = copy.deepcopy(object_value(descriptor["configuration"]))
    configuration["service"] = {"flush": 1, "grace": 1, "log_level": "warn"}
    pipeline = object_value(configuration["pipeline"])
    inputs = rows(pipeline["inputs"])
    shard = (
        "applications_a"
        if service in ("marshall", "lilly", "porsche", "audi")
        else "applications_b"
    )
    source = next(
        (
            row
            for row in inputs
            if any(
                processor.get("call") == f"normalize_{shard}"
                for processor in rows(object_value(row["processors"])["logs"])
            )
        ),
        inputs[0],
    )
    pipeline["inputs"] = [source]
    source.update(
        name="dummy",
        samples=1,
        dummy=json.dumps(
            {
                "_SYSTEMD_UNIT": "marshall-overalls.service"
                if service == "marshall"
                else f"{service}.service",
                "__CURSOR": "fixture-cursor",
                "SYSLOG_IDENTIFIER": "forged-service",
                "MESSAGE": json.dumps(payload),
            }
        ),
    )
    for key in ("db", "db.sync", "read_from_tail", "strip_underscores", "storage.type"):
        source.pop(key, None)
    for metric in rows(pipeline["filters"]):
        metric["flush_interval_sec"] = 1
    port = 0
    for output in rows(pipeline["outputs"]):
        output.pop("_credential_files", None)
        output.pop("storage.total_limit_size", None)
        if prometheus and output.get("name") == "prometheus_exporter":
            with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as available:
                available.bind(("127.0.0.1", 0))
                port = available.getsockname()[1]
            output["port"] = port
            assert output["host"] == "127.0.0.1"
    with tempfile.TemporaryDirectory() as temporary:
        path = Path(temporary) / "config.yaml"
        object_value(configuration["service"])["storage.path"] = str(Path(temporary) / "chunks")
        object_value(configuration["service"])["storage.sync"] = "full"
        path.write_text(json.dumps(configuration))
        executable = descriptor["executable"]
        assert isinstance(executable, str)
        env = dict(
            os.environ,
            OVERALLS_LOG_MACHINE="fixture-machine",
            OVERALLS_LOG_HOSTNAME="fixture-host",
            OVERALLS_LOG_ENVIRONMENT="fixture",
        )
        process = subprocess.Popen(
            [executable, "-c", str(path)], env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE
        )
        exposition = b""
        if prometheus:
            assert port > 0
            until = time.monotonic() + wait_seconds
            while time.monotonic() < until:
                try:
                    with urllib.request.urlopen(
                        f"http://127.0.0.1:{port}/metrics", timeout=0.2
                    ) as reply:
                        exposition = reply.read(65537)
                    assert len(exposition) <= 65536
                    if all(token in exposition for token in ready):
                        break
                except (urllib.error.URLError, TimeoutError):
                    pass
                time.sleep(0.05)
        try:
            stdout, stderr = process.communicate(timeout=5)
        except subprocess.TimeoutExpired:
            process.terminate()
            stdout, stderr = process.communicate(timeout=10)
        return stdout, stderr, exposition


def run(
    descriptor: dict[str, object],
    service: str,
    *,
    prometheus: bool = False,
    application_logs: bool = True,
) -> None:
    started = int(time.time())
    payload: dict[str, object] = {
        "message": "Runtime metrics observed",
        "metadata": {
            "event": f"{service}.runtime_metrics",
            "beam_memory_bytes": 123456,
            "ssh_count": 7,
            "ssh_duration_us": 2500,
            "terminal_authority_count": 9,
            "terminal_host_streams": 4,
            "trace_pending": 999,
            "runtime_observed_at_seconds": 1,
        },
    }
    gauges = (
        "ssh_count",
        "ssh_duration_ms",
        "terminal_authority_count",
        "terminal_host_streams",
        "runtime_observed_at_seconds",
    )
    stdout, stderr, exposition = emit(
        descriptor,
        service,
        payload,
        prometheus=prometheus,
        ready=tuple(f"overalls_gauge_{name}{{".encode() for name in gauges),
        wait_seconds=30.0,
    )
    numeric = exposition if prometheus else stdout
    label = f'service="{service}"'.encode()
    assert label in numeric and b"123456" in numeric, "native metric was not exported"
    for name, number in [
        ("ssh_count", "7"),
        ("ssh_duration_ms", "2.5"),
        ("terminal_authority_count", "9"),
        ("terminal_host_streams", "4"),
    ]:
        assert re.search(
            f"overalls_gauge_{name}".encode()
            + rb"\{[^\n]*"
            + re.escape(label)
            + rb"[^\n]*\} (?:= )?"
            + number.encode()
            + rb"(?:\s|$)",
            numeric,
        ), "catalogued numeric metric was not exported"
    assert b"overalls_gauge_trace_pending" not in numeric
    if prometheus:
        observed = re.search(
            rb"overalls_gauge_runtime_observed_at_seconds\{[^\n}]*\} ([0-9]+)(?:\s|$)",
            exposition,
        )
        assert observed is not None
        assert started <= int(observed.group(1)) <= int(time.time())
    if application_logs:
        assert b"fixture-machine:fixture-cursor" in stdout
        assert b'"hostname"=>"fixture-host"' in stdout
    else:
        assert b"fixture-machine:fixture-cursor" not in stdout
    assert b"given value field is empty" not in stderr


def refuse_retired_summary(descriptor: dict[str, object], service: str) -> None:
    """An application unit's retired metrics.summary shape MUST NOT become gauges."""
    payload: dict[str, object] = {
        "event": "metrics.summary",
        "metrics": {"beam_memory_bytes": 123456, "ssh_count": 7},
    }
    stdout, stderr, _ = emit(descriptor, service, payload, prometheus=False)
    assert b"fixture-machine:fixture-cursor" in stdout, "source log was not delivered"
    assert b"overalls_gauge_" not in stdout, "retired application summary was projected"
    assert b"given value field is empty" not in stderr


def run_health(
    descriptor: dict[str, object],
    brady_health: dict[str, object],
    *,
    application_logs: bool = True,
) -> None:
    """Prove trusted service attribution and closed SDK health projection natively."""
    values = {
        "trace_available": 1,
        "trace_pending": 17,
        "trace_queue_dropped": 23,
        "trace_export_failed": 29,
    }
    assert brady_health == {"event": "brady.observability_health", **values}, (
        "actual Brady formatter must preserve exactly its reviewed flat health fields"
    )
    for service in ("marshall", "lilly", "audi", "brady", "porsche", "ziggy", "enrico", "galileo"):
        started = int(time.time())
        payload: dict[str, object] = (
            {
                **brady_health,
                "ssh_count": 999,
                "provider_body": "private-fixture",
                "trace_observed_at_seconds": 1,
                "hostname": "forged-host",
                "unit": "audi.service",
            }
            if service == "brady"
            else {
                "message": "Observability producer health observed",
                "metadata": {
                    "event": f"{service}.observability_health",
                    **values,
                    "ssh_count": 999,
                    "provider_body": "private-fixture",
                    "trace_observed_at_seconds": 1,
                },
            }
        )
        stdout, stderr, exposition = emit(
            descriptor,
            service,
            payload,
            prometheus=True,
            ready=tuple(
                f"overalls_gauge_{name}{{".encode()
                for name in (*values, "trace_observed_at_seconds")
            ),
            wait_seconds=30.0,
        )
        for name, number in values.items():
            measurement = re.search(
                f"overalls_gauge_{name}".encode()
                + rb"\{([^\n}]*)\} "
                + str(number).encode()
                + rb"(?:\s|$)",
                exposition,
            )
            assert measurement is not None, f"reviewed health metric absent for {service}"
            labels = dict(re.findall(rb'(\w+)="([^"]*)"', measurement.group(1)))
            assert labels == {
                b"environment": b"fixture",
                b"service": service.encode(),
                b"hostname": b"fixture-host",
                b"unit": b"marshall-overalls.service"
                if service == "marshall"
                else f"{service}.service".encode(),
            }
        observed = re.search(
            rb"overalls_gauge_trace_observed_at_seconds\{[^\n}]*\} ([0-9]+)(?:\s|$)",
            exposition,
        )
        assert observed is not None
        assert started <= int(observed.group(1)) <= int(time.time())
        assert b"overalls_gauge_ssh_count" not in exposition
        if application_logs:
            assert f'"source"=>"{service}"'.encode() in stdout
            assert b"fixture-machine:fixture-cursor" in stdout
            assert b'"hostname"=>"fixture-host"' in stdout
            assert (
                b"brady.observability_health"
                if service == "brady"
                else b"Observability producer health observed"
            ) in stdout
        else:
            assert b"private-fixture" not in stdout
            assert b"Observability producer health observed" not in stdout
            assert b"fixture-machine:fixture-cursor" not in stdout
            assert b"brady.observability_health" not in stdout
        assert b"given value field is empty" not in stderr

    invalid: tuple[dict[str, object], ...] = (
        {
            "event": "lilly.observability_health",
            "message": "Observability producer health observed",
            "metadata": {"event": "audi.observability_health", **values},
        },
        {
            "message": "Observability producer health observed",
            "metadata": {
                "event": "lilly.observability_health",
                "trace_available": 2,
                "trace_pending": -1,
                "trace_queue_dropped": 1.5,
                "trace_export_failed": "29",
            },
        },
    )
    for payload in invalid:
        _, _, exposition = emit(descriptor, "lilly", payload, prometheus=True)
        for name in values:
            assert f"overalls_gauge_{name}".encode() not in exposition
    rejected: tuple[tuple[str, dict[str, object]], ...] = (
        ("audi", brady_health),
        ("audi", {**brady_health, "event": "audi.observability_health"}),
        (
            "brady",
            {
                **brady_health,
                "trace_available": 2,
                "trace_pending": -1,
                "trace_queue_dropped": 1.5,
                "trace_export_failed": "29",
            },
        ),
        ("brady", {**brady_health, "metadata": {"event": "audi.observability_health", **values}}),
    )
    for service, payload in rejected:
        _, _, exposition = emit(descriptor, service, payload, prometheus=True)
        for name in values:
            assert f"overalls_gauge_{name}".encode() not in exposition
    for service in ("marshall", "lilly", "porsche"):
        run(
            descriptor,
            service,
            prometheus=True,
            application_logs=application_logs,
        )


def main() -> None:
    raw: object = json.loads(Path(sys.argv[1]).read_text())
    descriptor = object_value(raw)
    service = sys.argv[2] if len(sys.argv) > 2 else "lilly"
    if service == "--health":
        brady_raw: object = json.loads(Path(sys.argv[3]).read_text())
        run_health(descriptor, object_value(brady_raw))
    elif service == "--numeric-only":
        brady_raw = json.loads(Path(sys.argv[3]).read_text())
        run_health(descriptor, object_value(brady_raw), application_logs=False)
    else:
        run(descriptor, service)
        refuse_retired_summary(descriptor, service)
    print("Catalogued metrics, retired summary refusal and trusted origin passed")


if __name__ == "__main__":
    main()
