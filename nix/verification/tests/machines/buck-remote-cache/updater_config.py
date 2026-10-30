"""Write a checkout's .buckconfig.local exactly as the host updater does."""

import importlib.util
import json
import sys
from pathlib import Path

spec = importlib.util.spec_from_file_location("updater", "/etc/updater-runtime.py")
if spec is None or spec.loader is None:
    raise RuntimeError("updater runtime unavailable")
updater = importlib.util.module_from_spec(spec)
spec.loader.exec_module(updater)

raw: object = json.loads(Path("/etc/updater-remote-cache.json").read_text())
local, state = updater.buck2_local_config(updater.remote_cache_value(raw))
Path(sys.argv[1]).write_text(local)
print(state)
