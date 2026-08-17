#!/usr/bin/env python3
"""check that each board's gowin project lists exactly the rtl it needs

this started as "every file in rtl/ must be listed", which was wrong in a way
that cost a build. apb_spi.v and apb_i2c.v exist because the generator can emit
them, but the gw5a25 board's mcu.yaml instantiates neither, so listing them put
two modules in the project that nothing instantiates. gowin picks the top module
by looking for exactly that, and with TopModule unset it chose a peripheral. the
symptom is every pin in pins.cst failing with

  CT1135 Can't find object named 'HCLK'

which points at the constraints and has nothing to do with them.

so the rule is not "everything on disk". it is the fixed core, debug and mcu
files, plus exactly the peripheral modules this board's mcu.yaml asks for. that
catches a missing file, a stale one, and an unused one that would reintroduce
the top level ambiguity.
"""

import glob
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import yaml

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PERIPH_DIR = os.path.join(ROOT, "tools", "peripherals")


def pipeline_selected():
    """is the 3-stage core selected in rtl/mcu/m1core_mcu.v

    the two cores are alternatives, and whichever one is not selected must not
    be in the project at all. gowin picks a top module by looking for one that
    nothing instantiates, so an unused core there is picked as top and every
    pin in the .cst then fails to bind, which reads as a constraints problem
    and is not one. that cost a build once already
    """
    with open(os.path.join(ROOT, "rtl", "mcu", "m1core_mcu.v")) as f:
        for line in f:
            stripped = line.strip()
            if stripped.startswith("`define M1CORE_PIPELINE"):
                return True
    return False


def required_for(board_dir):
    """the rtl this board actually instantiates"""
    need = set()
    for sub in ("core", "debug", "mcu"):
        for path in glob.glob(os.path.join(ROOT, "rtl", sub, "*.v")):
            need.add(os.path.relpath(path, ROOT))

    pipe = pipeline_selected()
    if pipe:
        need.discard("rtl/core/m1core_cpu.v")
        for path in glob.glob(os.path.join(ROOT, "rtl", "pipe", "*.v")):
            need.add(os.path.relpath(path, ROOT))

    mcu_yaml = os.path.join(board_dir, "mcu.yaml")
    if not os.path.exists(mcu_yaml):
        return need, []
    with open(mcu_yaml) as f:
        mcu = yaml.safe_load(f)["mcu"]

    optional = set()

    unused = []
    used_types = {p["type"] for p in mcu.get("peripherals", [])}
    for fn in sorted(os.listdir(PERIPH_DIR)):
        if not fn.endswith(".yaml"):
            continue
        with open(os.path.join(PERIPH_DIR, fn)) as f:
            t = yaml.safe_load(f)
        rel = f"rtl/periph/{t['module']}.v"
        if t["type"] in used_types:
            need.add(rel)
        else:
            unused.append((t["type"], rel))
    return need, unused, optional


def main():
    projects = glob.glob(os.path.join(ROOT, "boards", "*", "*.gprj"))
    if not projects:
        print("no .gprj found, nothing to check")
        return 0

    failed = False
    for proj in projects:
        board_dir = os.path.dirname(proj)
        text = open(proj).read()

        listed = set()
        # the ide rewrites this file and converts relative paths to absolute
        # ones whenever the project is edited in the gui, so both forms have to
        # be understood or every rtl file reads as missing
        for m in re.finditer(r'path="([^"]+\.v)"', text):
            p = m.group(1)
            if os.path.isabs(p):
                p = os.path.relpath(p, ROOT)
            elif p.startswith("../../"):
                p = p[len("../../"):]
            listed.add(p)

        name = os.path.relpath(proj, ROOT)
        need, unused, optional = required_for(board_dir)
        rtl_listed = {p for p in listed if p.startswith("rtl/")}

        for p in sorted(need - rtl_listed):
            print(f"FAIL {name}: {p} is needed but not listed")
            failed = True
        for p in sorted(rtl_listed - need - optional):
            if not os.path.exists(os.path.join(ROOT, p)):
                print(f"FAIL {name}: {p} is listed but does not exist")
            else:
                kind = dict((rel, t) for t, rel in unused).get(p)
                print(f"FAIL {name}: {p} is listed but this board has no "
                      f"{kind or 'instance'}, so nothing instantiates it and "
                      f"gowin may pick it as the top module")
            failed = True

        # a second candidate top module is the same trap the two cpus have.
        # gowin picks a top by finding a module nothing instantiates, so an ip
        # core sitting in the file list unreferenced competes with top.v and
        # every pin in pins.cst then fails to bind with CT1135. the gowin empu
        # m1 is the one that turns up here, because benchmarking against it
        # means generating it into this board directory; it belongs in
        # bench/empu_bench.gprj, not in this project
        for p in sorted(listed):
            if "empu" in p.lower():
                print(f"FAIL {name}: {p} is listed, and nothing instantiates "
                      f"it, so gowin may pick it as the top module instead of "
                      f"top.v. build it from boards/gw5a25/bench/ instead")
                failed = True

        if not failed:
            which = "pipelined" if pipeline_selected() else "multi-cycle"
            print(f"ok   {name}: {len(rtl_listed)} rtl files, "
                  f"matches what mcu.yaml instantiates ({which} core)")

    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
