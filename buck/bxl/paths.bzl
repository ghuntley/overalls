# Repository paths as Buck2 file labels, shared by the BXL scripts.

# Cells that are directories of the repository (see .buckconfig).
_CELLS = ["toolchains", "none"]

def file_label(path: str) -> str:
    cell, _, rest = path.partition("/")
    return "{}//{}".format(cell, rest) if cell in _CELLS else "root//" + path
