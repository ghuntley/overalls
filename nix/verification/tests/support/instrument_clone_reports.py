"""Instrument only the reviewed host-report guards in the clone fixture release."""

import hashlib
import sys
from pathlib import Path

HOST_REPORTS_SHA256 = "f31e1a86d889731f31bf37cdd26225e97c7d684440c546cd1772e4b8a1ed8f45"
EXCHANGE_SHA256 = "580a288a8b91f692b5d4aed87459be2471a70717a3cc301d008e9aac720bf6b3"

# Original operands remain in the original and-chain, evaluated exactly once.
REPLACEMENTS: tuple[tuple[str, str], ...] = (
    (
        "    age >= -1000 and age <= Marshall.Compute.HostLiveness.authority_ms() and\n      Enum.all?(snapshots, &valid_pool?/1) and\n      Enum.all?(snapshots, &observed_before?(&1, sampled_at)) and\n      Enum.sort(Enum.map(snapshots, & &1.id)) == Enum.sort(Enum.map(pools, & &1.id)) and\n      Enum.all?(snapshots, fn snapshot ->\n        storage_matches?(snapshot, Enum.find(pools, &(&1.id == snapshot.id)))\n      end)",
        "    Marshall.CloneReportRejectionFixture.check(:sample_future, age >= -1000, age) and\n      Marshall.CloneReportRejectionFixture.check(\n        :sample_expired, age <= Marshall.Compute.HostLiveness.authority_ms(), age\n      ) and\n      Marshall.CloneReportRejectionFixture.check(:pool_schema, Enum.all?(snapshots, &valid_pool?/1), age) and\n      Marshall.CloneReportRejectionFixture.check(\n        :pool_observed_at,\n        Enum.all?(snapshots, &observed_before?(&1, sampled_at)), age\n      ) and\n      Marshall.CloneReportRejectionFixture.check(\n        :pool_set,\n        Enum.sort(Enum.map(snapshots, & &1.id)) == Enum.sort(Enum.map(pools, & &1.id)), age\n      ) and\n      Marshall.CloneReportRejectionFixture.check(\n        :storage_identity,\n        Enum.all?(snapshots, fn snapshot ->\n          storage_matches?(snapshot, Enum.find(pools, &(&1.id == snapshot.id)))\n        end), age\n      )",
    ),
    (
        "defp valid?(_, _, _), do: false",
        "defp valid?(_, _, _), do: Marshall.CloneReportRejectionFixture.check(:report_shape, false, nil)",
    ),
    (
        "unless OverallsProtocol.Capacity.valid?(capacity), do: Ledger.rollback(:invalid_report)",
        "unless OverallsProtocol.Capacity.valid?(capacity) do\n      Marshall.CloneReportRejectionFixture.reject(:capacity_schema, DateTime.diff(now, report.sampled_at, :millisecond))\n      Ledger.rollback(:invalid_report)\n    end",
    ),
    (
        'if capacity &&\n         (capacity["cpu_headroom_millicores"] > report.effective_cores * 1000 or\n            capacity["memory_headroom_bytes"] > report.effective_memory_bytes),\n       do: Ledger.rollback(:invalid_report)',
        'if capacity &&\n         (capacity["cpu_headroom_millicores"] > report.effective_cores * 1000 or\n            capacity["memory_headroom_bytes"] > report.effective_memory_bytes) do\n      Marshall.CloneReportRejectionFixture.reject(:capacity_bounds, DateTime.diff(now, report.sampled_at, :millisecond))\n      Ledger.rollback(:invalid_report)\n    end',
    ),
    (
        "unless OverallsProtocol.ImageManifest.ids?(images),\n      do: Ledger.rollback(:invalid_report)",
        "unless OverallsProtocol.ImageManifest.ids?(images) do\n      Marshall.CloneReportRejectionFixture.reject(:image_ids, DateTime.diff(now, report.sampled_at, :millisecond))\n      Ledger.rollback(:invalid_report)\n    end",
    ),
    (
        'unless Map.get(report.inventory, "architecture") == Atom.to_string(host.architecture),\n      do: Ledger.rollback(:invalid_report)',
        'unless Map.get(report.inventory, "architecture") == Atom.to_string(host.architecture) do\n      Marshall.CloneReportRejectionFixture.reject(:architecture, DateTime.diff(now, report.sampled_at, :millisecond))\n      Ledger.rollback(:invalid_report)\n    end',
    ),
)


def instrument(source: str, exchange: str) -> str:
    """@cc [owner:ghuntley,label:verification] clone-report-exact-guard-seams
    The fixture build MUST refuse either changed source file before mutation.
    Instrument actual ingest_with_events_locked! guards reached by authenticated exchange;
    preserve predicate order, short-circuiting, evaluations and rollback reason.
    """
    for text, expected in ((source, HOST_REPORTS_SHA256), (exchange, EXCHANGE_SHA256)):
        if hashlib.sha256(text.encode()).hexdigest() != expected:
            raise ValueError("Clone report fixture source changed")
    for original, replacement in REPLACEMENTS:
        if source.count(original) != 1:
            raise ValueError("Clone report fixture guard changed")
        source = source.replace(original, replacement, 1)
    return source


def main() -> None:
    source = Path(sys.argv[1])
    exchange = Path(sys.argv[2])
    source.write_text(instrument(source.read_text(), exchange.read_text()))


if __name__ == "__main__":
    main()
