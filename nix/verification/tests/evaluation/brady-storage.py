"""Isolated storage custody fixtures; these do not establish native ZFS acceptance."""

import importlib.util
import io
import sys
import unittest
from types import SimpleNamespace
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("brady_storage", sys.argv.pop(1))
if spec is None or spec.loader is None:
    raise RuntimeError("brady storage helper unavailable")
s = importlib.util.module_from_spec(spec)
spec.loader.exec_module(s)


class StorageTest(unittest.TestCase):
    def config(self) -> dict[str, object]:
        return {
            "pool": {
                "storage": {"dataset": "tank/lilly", "dataset_guid": "456", "zpool_guid": "123"}
            },
            "dataset": "tank/brady-fixture",
            "host_id": "fixture",
        }

    def test_parent_mismatch_never_mutates(self) -> None:
        with (
            patch.object(s, "properties", return_value={"guid": "999"}),
            patch.object(s, "command") as command,
        ):
            with self.assertRaises(ValueError):
                s.prepare(self.config())
            command.assert_not_called()

    def test_cache_cannot_be_inside_guest_parent(self) -> None:
        config = self.config()
        config["dataset"] = "tank/lilly/brady"
        with patch.object(s, "command") as command:
            with self.assertRaises(ValueError):
                s.prepare(config)
            command.assert_not_called()

    def test_unowned_dataset_is_not_adopted(self) -> None:
        def properties(config: object, dataset: str, names: list[str]) -> dict[str, str]:
            if names == ["guid"]:
                return {"guid": "456"}
            if dataset == "tank":
                return {"used": str(10 * s.GIB), "available": str(90 * s.GIB)}
            return {"org.overalls:brady-host": "other"}

        with (
            patch.object(s, "properties", side_effect=properties),
            patch.object(s, "command", side_effect=["123", "tank\ntank/brady-fixture"]) as command,
        ):
            with self.assertRaisesRegex(ValueError, "cache_dataset_not_owned"):
                s.prepare(self.config())
            self.assertEqual(command.call_count, 2)
            self.assertTrue(
                all(call.args[2][0] in ("get", "list") for call in command.call_args_list)
            )

    def test_pressure_is_native_read_only_and_rejects_snapshot_descendants(self) -> None:
        values = {
            "guid": "456",
            "used": "10000000",
            "available": "90000000",
            "readonly": "off",
            "reservation": "0",
            "refreservation": "0",
            "org.overalls:brady-host": "fixture",
            "mountpoint": s.MOUNT,
            "mounted": "yes",
            "quota": "10000000",
            "refquota": "10000000",
            "usedbysnapshots": "0",
        }
        descendants = ["tank/brady-fixture"]

        def command(config: object, tool: str, args: list[str]) -> str:
            if tool == "zpool":
                return "123"
            if args[0] == "list":
                return descendants[0]
            self.assertEqual(args[:4], ["get", "-Hp", "-o", "name,property,value"])
            names = args[4].split(",")
            return "\n".join(
                f"{dataset}\t{name}\t{values[name]}" for dataset in args[5:] for name in names
            )

        def proc(path: str, **kwargs: object) -> io.StringIO:
            return io.StringIO(
                "100.00 100.00"
                if path == "/proc/uptime"
                else "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
            )

        with (
            patch.object(s, "command", side_effect=command) as fake,
            patch.object(s.os.path, "ismount", return_value=True),
            patch.object(s.os.path, "realpath", return_value=s.MOUNT),
            patch.object(s.os, "stat", return_value=SimpleNamespace(st_dev=s.os.makedev(0, 99))),
            patch("builtins.open", side_effect=proc),
        ):
            value = s.observe(self.config())
            self.assertEqual(value["observed_ms"], 100000)
            self.assertEqual(value["device"], "0:99")
            self.assertEqual(value["pool_total_bytes"], 100000000)
            self.assertTrue(all(call.args[2][0] in ("get", "list") for call in fake.call_args_list))
            # Pool identity, one combined property read and the descendant list.
            self.assertEqual(fake.call_count, 3)
            descendants[0] = "tank/brady-fixture\ntank/brady-fixture@snapshot"
            with self.assertRaisesRegex(ValueError, "unexpected_cache_descendants"):
                s.observe(self.config())

    def test_combined_properties_require_exact_pairs(self) -> None:
        names = {"tank/lilly": ["guid", "used"], "tank": ["used"]}
        complete = "tank/lilly\tguid\t456\ntank/lilly\tused\t1\ntank\tguid\t1\ntank\tused\t2"
        with patch.object(s, "command", return_value=complete):
            self.assertEqual(
                s.dataset_properties(self.config(), names),
                {"tank/lilly": {"guid": "456", "used": "1"}, "tank": {"used": "2"}},
            )
        for output in (
            "tank/lilly\tguid\t456\ntank/lilly\tused\t1\ntank\tused\t2",
            complete + "\ntank\tused\t3",
            complete + "\ntank/other\tused\t3",
            complete + "\nmalformed",
        ):
            with (
                patch.object(s, "command", return_value=output),
                self.assertRaisesRegex(ValueError, "invalid_storage_properties"),
            ):
                s.dataset_properties(self.config(), names)

    def test_sampler_cadence_counts_slow_samples(self) -> None:
        clock = [10.0]
        sleeps: list[float] = []

        def observe(config: object) -> object:
            clock[0] += 0.75
            raise ValueError("fixture")

        def sleep(seconds: float) -> None:
            sleeps.append(seconds)
            clock[0] += seconds
            if len(sleeps) == 2:
                raise KeyboardInterrupt

        with (
            patch.object(s, "observe", side_effect=observe),
            patch.object(s.time, "monotonic", side_effect=lambda: clock[0]),
            patch.object(s.time, "sleep", side_effect=sleep),
            self.assertRaises(KeyboardInterrupt),
        ):
            s.publish_pressure(self.config())
        self.assertEqual(sleeps, [0.25, 0.25])

    def test_command_output_is_bounded(self) -> None:
        with self.assertRaisesRegex(ValueError, "storage_output_limit"):
            s.command({"fixture": sys.executable}, "fixture", ["-c", "print('x' * 70000)"])


unittest.main()
