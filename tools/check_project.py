#!/usr/bin/env python3
"""check that every RTL file on disk is listed in each board's gowin project

these two lists drifted once already: m1core_nvic.v was added to the simulation
build but not to the .gprj, and nothing noticed until GowinSynthesis failed with
"Instantiating unknown module". simulation passes happily because iverilog is
given its own file list, so this is the only cheap way to catch it.
"""

import glob
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def main():
    on_disk = set()
    for path in glob.glob(os.path.join(ROOT, "rtl", "*", "*.v")):
        on_disk.add(os.path.relpath(path, ROOT))

    projects = glob.glob(os.path.join(ROOT, "boards", "*", "*.gprj"))
    if not projects:
        print("no .gprj found, nothing to check")
        return 0

    failed = False
    for proj in projects:
        text = open(proj).read()
        listed = set()
        for m in re.finditer(r'path="([^"]+\.v)"', text):
            p = m.group(1)
            if p.startswith("../../"):
                listed.add(p[len("../../"):])

        name = os.path.relpath(proj, ROOT)
        missing = sorted(on_disk - listed)
        stale = sorted(p for p in listed - on_disk if p.startswith("rtl/"))

        for p in missing:
            print(f"FAIL {name}: {p} is not listed")
            failed = True
        for p in stale:
            print(f"FAIL {name}: {p} is listed but does not exist")
            failed = True

        if not missing and not stale:
            print(f"ok   {name}: {len(listed)} rtl files, matches disk")

    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
