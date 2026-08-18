#!/usr/bin/env python3
"""Keep the empu benchmark's place and route settings identical to m1core's.

The benchmark only means something if both projects are given the same job.
The clock is the obvious half of that and the one everybody checks; the place
and route options are the half that is invisible, because they live in a 91 key
json that the ide rewrites whenever it feels like it.

Two keys are allowed to differ, and have to: they are the project's identity
rather than settings. Copying a config wholesale to inherit the dual purpose
pin options -- which is the only reason to copy it, since CPU and SSPI have to
be true for HCLK to reach E2 -- carries the identity too, and the symptom is
`ERROR (EX0302) : No valid top module found` after every file has parsed
cleanly. See boards/gw5a25/bench/README.md.
"""

import json
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
MAIN = os.path.join(ROOT, "boards/gw5a25/impl/m1core_process_config.json")
BENCH = os.path.join(ROOT, "boards/gw5a25/bench/impl/empu_bench_process_config.json")

MAIN_GPRJ = os.path.join(ROOT, "boards/gw5a25/m1core.gprj")
BENCH_GPRJ = os.path.join(ROOT, "boards/gw5a25/bench/empu_bench.gprj")

# per project names, not settings
IDENTITY = {
    "TopModule": ("top", "empu_bench_top"),
    "OUTPUT_BASE_NAME": ("m1_soc", "empu_bench"),
}


def device(gprj):
    """the <Device name=.. pn=..>id</Device> line, as (pn, id)

    both halves matter. changing the speed grade in the ide rewrites the part
    number AND the trailing id -- NES is gw5a25a-000, NC1/I0 is gw5a25a-002 --
    so a project carrying one of each is not the part you think it is
    """
    if not os.path.exists(gprj):
        return None
    m = re.search(r'<Device\s+name="([^"]*)"\s+pn="([^"]*)"\s*>([^<]*)</Device>',
                  open(gprj).read())
    return (m.group(2), m.group(3)) if m else None


def check_device():
    """the benchmark is meaningless if the two are built for different silicon.

    this is not hypothetical: the project ran for most of its life set to
    GW5A-LV25MG121NES while the die is marked MG121NC1/I0, so every 25k number
    before 2026-08-17 was measured against the wrong delay model. when that was
    corrected in the ide it was corrected in one project and not the other
    """
    a, b = device(MAIN_GPRJ), device(BENCH_GPRJ)
    if a is None or b is None:
        return False
    if a != b:
        print(f"FAIL part number differs. m1core is {a[0]} ({a[1]}), bench is "
              f"{b[0]} ({b[1]}). the delay models follow the speed grade, so "
              f"these two reports are not comparable")
        return True
    print(f"ok   both projects are {a[0]}")
    return False


def main():
    if not os.path.exists(BENCH):
        print("ok   no empu benchmark project, nothing to compare")
        return 0
    if not os.path.exists(MAIN):
        print(f"FAIL {MAIN} is missing")
        return 1

    with open(MAIN) as f:
        main_cfg = json.load(f)
    with open(BENCH) as f:
        bench_cfg = json.load(f)

    failed = check_device()

    for key, (want_main, want_bench) in IDENTITY.items():
        for name, cfg, want in (("m1core", main_cfg, want_main),
                                ("bench", bench_cfg, want_bench)):
            got = cfg.get(key)
            if got != want:
                print(f"FAIL {name} {key} is {got!r}, expected {want!r}")
                failed = True

    shared = (set(main_cfg) | set(bench_cfg)) - set(IDENTITY)
    for key in sorted(shared):
        a = main_cfg.get(key, "<missing>")
        b = bench_cfg.get(key, "<missing>")
        if a != b:
            print(f"FAIL {key}: m1core has {a!r}, bench has {b!r}. the "
                  f"benchmark is only a comparison if both projects are given "
                  f"the same job")
            failed = True

    if not failed:
        print(f"ok   bench p&r config matches m1core across "
              f"{len(shared)} settings "
              f"(Place_Option {main_cfg.get('Place_Option')}, "
              f"Route_Option {main_cfg.get('Route_Option')}, "
              f"Replicate_Resources {main_cfg.get('Replicate_Resources')})")

    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
