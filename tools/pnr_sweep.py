#!/usr/bin/env python3
"""sweep gowin place and route options headless, and tabulate what came back

Every timing number in this project so far came from a single build with more
than one thing changed between it and the last one, which is how a 19% spread
got mistaken for a regression and back again. This runs the vendor flow from a
script instead, one variable at a time, and writes a csv.

    python3 tools/pnr_sweep.py --list
    python3 tools/pnr_sweep.py --place 0,1,2,3,4
    python3 tools/pnr_sweep.py --place 2 --route 0,1,2 --board mega60k

A build is roughly 90 minutes, so `--place 0,1,2,3,4` is an overnight run. It
prints each result as it lands and appends to tools/sweep-<board>.csv, so an
interrupted sweep still leaves everything it finished.

---- what is actually adjustable, probed rather than assumed ----

set_option validates names: an invalid one prints "unknown option" and the tcl
catch returns non-zero. Probing the whole plausible namespace against the real
project gave these, and only these, as accepted:

    place_option        0-4   REJECTS 5. the ide dropdown offers 0-2
    route_option        0-2   rejects 3
    route_maxfan        int   23 is the project default
    timing_driven       0-2
    retiming            0-2
    resource_sharing    0-2
    clock_route_order   0-2

and these were NOT accepted, so they do not exist in V1.9.12:

    seed, place_seed, random_seed, router_seed   no placement seed
    effort, place_effort, route_effort           no separate effort control
    synthesis_effort, optimization_level

The absence of a seed is the important one. Seed sweeping is the usual way to
characterise placement variance, and it is not available here, so the only way
to sample the same configuration twice is to run it twice -- which `--repeat`
does, and which is worth doing once to learn the noise floor before reading
anything into a difference between two configurations.
"""

# WARNING, learned the hard way: set_option WRITES the project's
# impl/<name>_process_config.json. It is not a per-run override. A probe session
# that walked the option space left this project on place_option=4,
# route_maxfan=100 and TopModule=1 -- that last one is the EX0302 "No valid top
# module found" failure -- and boards/*/impl is gitignored, so there was no
# backup to go back to. This tool snapshots the config before it starts and puts
# it back afterwards, including on ctrl-c.

import argparse
import csv
import glob
import html
import os
import re
import subprocess
import sys
import time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

# probed against the real project, see the module docstring
OPTIONS = {
    "place_option": (0, 4),
    "route_option": (0, 2),
    "timing_driven": (0, 2),
    "retiming": (0, 2),
    "resource_sharing": (0, 2),
    "clock_route_order": (0, 2),
    "route_maxfan": (1, 1000),
}


def find_ide():
    """the gowin ide, newest version first"""
    hits = sorted(glob.glob(os.path.expanduser("~/Downloads/Gowin_*/IDE")))
    hits = [h for h in hits if os.path.exists(os.path.join(h, "bin", "gw_sh"))]
    if not hits:
        sys.exit("no gowin ide found under ~/Downloads/Gowin_*/IDE")
    return hits[-1]


def gw_env(ide):
    """gw_sh needs the bundled qt and a headless platform plugin.

    the system qt loses with "Cannot mix incompatible Qt library", and of the
    platform plugins only `minimal` works: `offscreen` wants GLX, `linuxfb`
    wants a tty. it still prints a createPlatformOpenGLContext warning and then
    runs fine
    """
    env = dict(os.environ)
    env["QT_QPA_PLATFORM"] = "minimal"
    env["LD_LIBRARY_PATH"] = os.path.join(ide, "lib")
    return env


def report_path(board):
    d = os.path.join(ROOT, "boards", board, "impl", "pnr")
    hits = glob.glob(os.path.join(d, "*_tr_content.html"))
    return hits[0] if hits else None


def parse_report(path):
    """fmax, tns, violated endpoint counts and the worst path, from the html"""
    t = open(path, errors="ignore").read()
    plain = html.unescape(re.sub("<[^>]+>", " ", t))
    plain = re.sub(r"\s+", " ", plain)

    out = {}
    m = re.search(r"Numbers of Setup Violated Endpoints\s+(\d+)", plain)
    out["setup_viol"] = int(m.group(1)) if m else ""
    m = re.search(r"Numbers of Hold Violated Endpoints\s+(\d+)", plain)
    out["hold_viol"] = int(m.group(1)) if m else ""

    # the generated clock's row, not HCLK's: take the last constraint/fmax pair
    pairs = re.findall(r"([\d.]+)\(MHz\)\s+([\d.]+)\(MHz\)\s+(\d+)", plain)
    if pairs:
        out["constraint"] = pairs[-1][0]
        out["fmax"] = float(pairs[-1][1])
        out["levels"] = pairs[-1][2]

    m = re.search(r"Setup\s+(-?[\d.]+)\s+(\d+)", plain)
    if m:
        out["tns"] = m.group(1)

    # worst setup path, the first data row of the setup table
    i = plain.find("Setup Paths Table")
    m = re.search(r"1\s+(-?[\d.]+)\s+(\S+)\s+(\S+)", plain[i:i + 4000]) if i > 0 else None
    if m:
        out["worst_slack"] = m.group(1)
        out["worst_from"] = m.group(2)
        out["worst_to"] = m.group(3)
    return out


def run_one(board, opts, ide, keep_dir):
    """one full synth+pnr with these options, returns the parsed report"""
    gprj = os.path.join(ROOT, "boards", board, "m1core.gprj")
    if not os.path.exists(gprj):
        sys.exit("no project at %s" % gprj)

    lines = ["open_project %s" % gprj]
    for k, v in sorted(opts.items()):
        lines.append("set_option -%s %s" % (k, v))
    lines.append("run all")
    tcl = os.path.join(keep_dir, "run.tcl")
    open(tcl, "w").write("\n".join(lines) + "\n")

    t0 = time.time()
    p = subprocess.run([os.path.join(ide, "bin", "gw_sh"), tcl],
                       env=gw_env(ide), cwd=ROOT,
                       capture_output=True, text=True)
    took = time.time() - t0

    rpt = report_path(board)
    if rpt is None:
        return {"error": "no timing report produced", "secs": int(took),
                "log": p.stdout[-400:]}

    res = parse_report(rpt)
    res["secs"] = int(took)
    # keep this run's report, the next run overwrites it in place
    tag = "-".join("%s%s" % (k[:2], v) for k, v in sorted(opts.items()))
    try:
        open(os.path.join(keep_dir, "report-%s.html" % tag), "w").write(
            open(rpt, errors="ignore").read())
    except OSError:
        pass
    return res


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--board", default="gw5a25")
    ap.add_argument("--repeat", type=int, default=1,
                    help="run each configuration N times, to see the noise floor")
    ap.add_argument("--list", action="store_true",
                    help="print the probed option ranges and exit")
    ap.add_argument("--dry-run", action="store_true")
    for k in OPTIONS:
        ap.add_argument("--" + k.replace("_option", "").replace("_", "-"),
                        dest=k, default=None,
                        help="comma separated values, %d-%d" % OPTIONS[k])
    a = ap.parse_args()

    if a.list:
        print("probed accepted options for this ide:")
        for k, (lo, hi) in sorted(OPTIONS.items()):
            print("  %-18s %d-%d" % (k, lo, hi))
        print("\nno seed and no effort option exists, see the module docstring")
        return 0

    # cartesian product of whatever was given
    grids = []
    for k in OPTIONS:
        if getattr(a, k) is not None:
            vals = [v.strip() for v in getattr(a, k).split(",")]
            for v in vals:
                lo, hi = OPTIONS[k]
                if not (v.isdigit() and lo <= int(v) <= hi):
                    sys.exit("%s=%s is outside the accepted range %d-%d" % (k, v, lo, hi))
            grids.append([(k, v) for v in vals])
    if not grids:
        sys.exit("nothing to sweep. try --place 0,1,2,3,4 or --list")

    combos = [{}]
    for g in grids:
        combos = [dict(c, **{k: v}) for c in combos for k, v in g]
    combos = [c for c in combos for _ in range(a.repeat)]

    ide = find_ide()
    cfgs = glob.glob(os.path.join(ROOT, "boards", a.board, "impl",
                                  "*_process_config.json"))
    saved = {c: open(c).read() for c in cfgs}
    globals()["_saved"] = saved
    if not saved:
        sys.exit("no process_config.json found for %s, refusing to run: "
                 "set_option would write one and there would be nothing to "
                 "restore" % a.board)
    keep = os.path.join(ROOT, "tools", "sweep-%s" % a.board)
    os.makedirs(keep, exist_ok=True)
    csv_path = os.path.join(ROOT, "tools", "sweep-%s.csv" % a.board)

    print("ide      %s" % ide)
    print("board    %s" % a.board)
    print("runs     %d, about %d minutes each" % (len(combos), 90))
    for c in combos:
        print("         %s" % c)
    if a.dry_run:
        return 0

    fields = ["when"] + sorted(OPTIONS) + ["fmax", "constraint", "setup_viol",
                                           "hold_viol", "tns", "levels",
                                           "worst_slack", "worst_from",
                                           "worst_to", "secs", "error"]
    new = not os.path.exists(csv_path)
    with open(csv_path, "a", newline="") as fh:
        w = csv.DictWriter(fh, fieldnames=fields, extrasaction="ignore")
        if new:
            w.writeheader()
        for n, opts in enumerate(combos, 1):
            print("\n[%d/%d] %s" % (n, len(combos), opts), flush=True)
            res = run_one(a.board, opts, ide, keep)
            row = dict(res)
            row.update(opts)
            row["when"] = time.strftime("%Y-%m-%d %H:%M")
            w.writerow(row)
            fh.flush()
            if "error" in res:
                print("  FAILED %s" % res["error"])
            else:
                print("  fmax %s  setup_viol %s  worst %s  %s -> %s  (%ds)" % (
                    res.get("fmax"), res.get("setup_viol"),
                    res.get("worst_slack"), res.get("worst_from"),
                    res.get("worst_to"), res.get("secs")))
    print("\nwrote %s" % csv_path)
    return 0


def restore(saved):
    for path, text in saved.items():
        open(path, "w").write(text)
        print("restored %s" % os.path.relpath(path, ROOT))


if __name__ == "__main__":
    # the snapshot lives in main(); this keeps the restore on the way out no
    # matter how we leave, because an interrupted sweep is the likely case
    _saved = {}
    try:
        sys.exit(main())
    finally:
        if globals().get("_saved"):
            restore(globals()["_saved"])
