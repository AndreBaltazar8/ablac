#!/usr/bin/env python3
"""Source/packaged entry point; Python standard library only, no implicit downloads."""
from pathlib import Path
import sys

if sys.version_info < (3, 9):
    raise SystemExit("abla-install-xtensa: Python 3.9 or newer is required")
sys.dont_write_bytecode = True
here = Path(__file__).resolve().parent
if (here / "xtensa_companions.py").is_file():
    sys.path.insert(0, str(here))
    import xtensa_companions
    xtensa_companions.installer_main()
else:
    root = here.parent
    helper = root / "libexec/abla"
    if not (helper / "xtensa_companions.py").is_file():
        raise SystemExit("abla-install-xtensa: installer helper is missing; reinstall the toolchain")
    sys.path.insert(0, str(helper))
    import xtensa_companions
    xtensa_companions.installer_main(root, root / "share/abla/xtensa-companions.json")
