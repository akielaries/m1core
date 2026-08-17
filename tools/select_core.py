#!/usr/bin/env python3
"""pick which cpu core the gowin build uses

the two cores are alternatives with the same port list, and exactly one of them
may be in the project at a time. that is not a style preference: gowin picks a
top module by looking for one that nothing instantiates, so leaving the unused
core in the project gets it chosen as top, and then every pin in pins.cst fails
to bind with

  CT1135 Can't find object named 'HCLK'

which points at the constraints and has nothing to do with them. that cost a
build once, so switching cores is a script rather than three edits that have to
agree with each other.

simulation does not use this. it selects with -DM1CORE_PIPELINE on the iverilog
command line, so both cores are always testable from the same checkout: `make
core` is the multi-cycle one and `make pipeline` is the 3-stage one.

usage: select_core.py [pipeline|multicycle]
       select_core.py            # report what is selected now
"""

import glob
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
MCU = os.path.join(ROOT, "rtl", "mcu", "m1core_mcu.v")
DEFINE = "`define M1CORE_PIPELINE"

MULTI = "rtl/core/m1core_cpu.v"


def pipe_files():
    return sorted(os.path.relpath(p, ROOT)
                  for p in glob.glob(os.path.join(ROOT, "rtl", "pipe", "*.v")))


def current():
    with open(MCU) as f:
        for line in f:
            if line.strip().startswith(DEFINE):
                return "pipeline"
    return "multicycle"


def set_define(want):
    with open(MCU) as f:
        text = f.read()
    # the define sits inside an `ifndef guard so simulation can also pass
    # -DM1CORE_PIPELINE without a redefinition warning. only the inner line is
    # toggled, so the guard survives either way
    if want == "pipeline":
        text = re.sub(r"^// `define M1CORE_PIPELINE$", DEFINE,
                      text, count=1, flags=re.M)
    else:
        text = re.sub(r"^`define M1CORE_PIPELINE$", "// " + DEFINE,
                      text, count=1, flags=re.M)
    with open(MCU, "w") as f:
        f.write(text)


def set_project(want):
    """add and remove file entries so exactly one core is in the project"""
    for proj in glob.glob(os.path.join(ROOT, "boards", "*", "*.gprj")):
        with open(proj) as f:
            text = f.read()

        # a template entry to clone, so whatever attributes the ide writes are
        # preserved rather than guessed at
        m = re.search(r'[ \t]*<File path="([^"]*m1core_decode\.v)"[^>]*/>\n',
                      text)
        if not m:
            print(f"skip {proj}: no decode entry to model new ones on")
            continue
        template, tmpl_path = m.group(0), m.group(1)
        prefix = tmpl_path[:tmpl_path.index("rtl/")]

        def entry(rel):
            return template.replace(tmpl_path, prefix + rel)

        def drop(rel):
            nonlocal text
            text = re.sub(r'[ \t]*<File path="[^"]*%s"[^>]*/>\n'
                          % re.escape(os.path.basename(rel)), "", text)

        if want == "pipeline":
            drop(MULTI)
            for rel in pipe_files():
                drop(rel)
            add = "".join(entry(rel) for rel in pipe_files())
        else:
            for rel in pipe_files():
                drop(rel)
            drop(MULTI)
            add = entry(MULTI)

        text = text.replace(template, template + add, 1)
        with open(proj, "w") as f:
            f.write(text)
        print(f"updated {os.path.relpath(proj, ROOT)}")


def main():
    if len(sys.argv) == 1:
        print(f"selected: {current()} core")
        return 0
    want = sys.argv[1]
    if want not in ("pipeline", "multicycle"):
        print(__doc__)
        return 2
    set_define(want)
    set_project(want)
    print(f"selected: {want} core")
    print("run tools/check_project.py to confirm, then rebuild the bitstream")
    return 0


if __name__ == "__main__":
    sys.exit(main())
