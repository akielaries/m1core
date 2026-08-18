#!/usr/bin/env python3
"""check each board's Gowin_PLL instantiation against the wrapper on disk

The pll wrapper's port list is not fixed. It varies by device family -- the
GW5AST part has `init_clk` where the GW5A has `mdclk`, and no `mdclk` at all --
and it also varies with what you tick in the IP generator: enabling mDRP adds
`mdopc`, `mdainc`, `mdwdi`, `mdrdo` and `pll_init_bypass`, and asking for more
outputs adds `clkoutN` and sometimes `enclkN`.

So a board's `top.v` cannot be written once and copied. Getting it wrong costs a
full synthesis run to find out:

  ERROR (EX3990) : Cannot find port 'mdopc' on this module
  ERROR (EX5998) : Cannot open Verilog file '.../gowin_pll.v'

Both of those are a second's work to detect here instead.

The check is deliberately one directional. Every port the instantiation names
must exist on the wrapper, because naming one that does not is EX3990. Ports on
the wrapper that the instantiation leaves out are fine -- they default to
unconnected, which is what you want for an output you are not using -- with one
exception worth shouting about: the init sequencer's clock. `mdclk` on GW5A and
GW5AT, `init_clk` on GW5AST. The generator writes `defparam CLK_PERIOD = 20`
into PLL_INIT, so it wants a real 50 MHz clock. Tied low or left unconnected
the pll never initialises and `lock` never rises, which presents as a board
that is simply dead.
"""

import glob
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

# a wrapper that has one of these must have it driven, or lock never rises
INIT_CLOCKS = ("mdclk", "init_clk")


def wrapper_ports(path):
    """the port names in `module Gowin_PLL( ... );`"""
    with open(path) as f:
        text = f.read()
    m = re.search(r"module\s+Gowin_PLL\s*\((.*?)\)\s*;", text, re.S)
    if not m:
        return None
    return {p.strip() for p in m.group(1).split(",") if p.strip()}


def instance_ports(path):
    """the .name() connections in the Gowin_PLL instantiation in a top.v"""
    with open(path) as f:
        text = f.read()
    m = re.search(r"Gowin_PLL\s+\w+\s*\((.*?)\)\s*;", text, re.S)
    if not m:
        return None
    return {n for n in re.findall(r"\.(\w+)\s*\(", m.group(1))}


def main():
    failed = False
    checked = 0

    for top in sorted(glob.glob(os.path.join(ROOT, "boards", "*", "top.v"))):
        board = os.path.basename(os.path.dirname(top))
        name = os.path.relpath(top, ROOT)

        inst = instance_ports(top)
        if inst is None:
            continue

        wrapper = os.path.join(ROOT, "boards", board,
                               "src", "gowin_pll", "gowin_pll.v")
        if not os.path.exists(wrapper):
            print(f"note {board}: pll not generated yet, "
                  f"src/gowin_pll/gowin_pll.v is missing. see boards/README.md")
            continue

        ports = wrapper_ports(wrapper)
        if ports is None:
            print(f"FAIL {board}: cannot find `module Gowin_PLL(...)` in "
                  f"{os.path.relpath(wrapper, ROOT)}")
            failed = True
            continue

        checked += 1

        missing = inst - ports
        if missing:
            print(f"FAIL {name}: connects {sorted(missing)}, which the "
                  f"generated wrapper does not have. it has "
                  f"{sorted(ports)}. this is EX3990 at synthesis")
            failed = True

        for clk in INIT_CLOCKS:
            if clk in ports and clk not in inst:
                print(f"FAIL {name}: the wrapper has `{clk}` and the "
                      f"instantiation leaves it unconnected. it clocks the "
                      f"pll init sequencer and wants HCLK; without it lock "
                      f"never rises and the board looks dead")
                failed = True

    if not failed:
        print(f"ok   {checked} board pll instantiation(s) match the wrapper "
              f"on disk")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
