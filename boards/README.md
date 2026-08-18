# boards

| directory | part | grade | notes |
| --- | --- | --- | --- |
| `gw5a25/` | `GW5A-LV25MG121NC1/I0` | **C1/I0** | tang primer 25k, where this was developed |
| `mega60k/` | `GW5AT-LV60PG484AC2/I1` | C2 | tang mega 60k |
| `mega138k/` | `GW5AST-LV138FPG676AC2/I1` | C2 | tang mega 138k |

A board is `top.v`, `pins.cst`, `timing.sdc`, `mcu.yaml` and a `.gprj`. Nothing
else: the SoC is `m1core_mcu` and it is shared. What actually differs between
these three is the part, the ball assignments, and **the reset polarity** --
the 25k has an active high key pulled down and inverts in its board layer, the
two megas bring out `hwRstn` active low and pulled up and do not. Getting that
backwards produces a board that never leaves reset or never enters it, and both
look like a dead bitstream rather than a one bit mistake.

## Results

m1core, same rtl, same sdc, 100 MHz asked for on all three:

| board | grade | Fmax | setup TNS | closes at 100? | logic |
| --- | --- | --- | --- | --- | --- |
| `gw5a25` | C1/I0 | 75.0 | -1562.8 over 1409 endpoints | no | 37% |
| `mega60k` | C2 | **100.140** | **0.000, 0 endpoints** | **yes** | 13% |
| `mega138k` | C2 | not built yet | | | |

**The 25k's ceiling was the part, and by more than was thought.** The part
number was set to `GW5A-LV25MG121NES` for most of this project's life, and the
die is marked `MG121NC1/I0`. So every 25k figure before 2026-08-17 -- 48.4
through 88.2 -- was measured against the WRONG delay model. The first number
measured against C1/I0 is 75.0.

C1/I0 is the slowest GW5A commercial grade; the megas are C2/I1. Same rtl, same
tools, same constraints, and a C2 device closes at 100 MHz where this one does
not. Gowin's own cortex-m1 reaches 82.0 and 87.7 on that same
25k, which is what said it was silicon rather than design in the first place.

Two things to read carefully before celebrating:

- **The worst slack on the 60k is 0.014 ns.** That is 0.1% margin. It is at the
  slow corner so it is a real pass, but it is not a number to ship on. And
  because the design now *meets* the constraint, `Actual Fmax` has stopped
  being a measurement -- the tool stops trying once it is satisfied. To find
  the real ceiling, raise the pll and re-measure, then set the shipping clock
  to about 90% of what comes back.
- **`SSRAM(RAM16)` is 0 and the register count did not move.** The register
  file is replicated four ways in the rtl, one array per read port, and the
  optimiser merged the copies back: four arrays with identical contents and a
  shared write port are provably the same thing. So it is still flops with four
  read muxes. Getting lut ram needs an explicit
  `syn_ramstyle = "distributed_ram"` attribute, not just the right shape. At
  13% logic on this part that is no longer worth chasing; on the 25k, where
  placement was the limit, it still might be.

## Why the megas are here

m1core reaches about 88 MHz on the 25k. Gowin's own Cortex-M1, built on the
same board through the same PLL with the same constraints, reaches 82.0 and
87.7 -- see `gw5a25/bench/README.md`. Two unrelated designs landing in the same
place is a part limit, not a design limit, and the obvious suspect is in the
table above: the 25k is a **C1/I0**, the slowest commercial grade, and the megas
are **C2/I1**.

So these boards answer a question the 25k cannot: how much of the ceiling is
silicon grade? Build the same RTL on all three and the difference is the part.

`pub/mega_60k_test` and `pub/mega_138k_test` already contain
`gowin_empu_m1`, so the eMPU numbers for those boards can be had the same way,
and the comparison stays like for like.

## Two steps before a new board builds

**1. Generate its PLL.** In the IDE, IP Core Generator > Hard Module > CLOCK >
PLL, into `boards/<board>/src/gowin_pll/`, **with that board's project open so
it is generated for that device**:

```
Common  > CLKIN 50.000, Enable Lock ticked
Clkout0 > the frequency in that board's mcu.yaml clock.hz
```

Without it the build stops at

```
ERROR (EX5998) : Cannot open Verilog file '.../src/gowin_pll/gowin_pll.v'
```

**The wrapper's port list is device family specific, and the three boards do
not agree.** This is why the PLL cannot simply be copied from one board to
another, and why each `top.v` has its own instantiation:

| board | family | ports |
| --- | --- | --- |
| `gw5a25` | GW5A | `clkin, clkout0, lock, mdclk` |
| `mega60k` | GW5AT | as above plus `reset` and the mdrp sideband: `mdopc, mdainc, mdwdi, mdrdo, pll_init_bypass` |
| `mega138k` | GW5AST | `clkin, init_clk, clkout0, enclk0, lock, reset` -- **no mdclk at all** |

**The options you tick change it too**, not only the device. The reference
projects have mDRP and three outputs enabled, so their wrappers also carry
`reset`, `mdopc`, `mdainc`, `mdwdi`, `mdrdo` and `pll_init_bypass`. A minimal
one-output PLL with lock has four ports and none of those, and connecting them
anyway is

```
ERROR (EX3990) : Cannot find port 'mdopc' on this module
```

So match the instantiation to the wrapper you actually generated, and check it
without spending a synthesis run:

```
python3 tools/check_pll.py
```

It reads each board's `top.v` and the wrapper on disk, fails on any port the
instantiation names that the wrapper does not have, and separately fails if the
wrapper has an init clock (`mdclk`, or `init_clk` on GW5AST) that the
instantiation leaves unconnected -- that one does not error at synthesis, it
just means `lock` never rises and the board looks dead.

Note that `mdclk` on the 25k and 60k, and `init_clk` on the 138k, want the same
thing for the same reason: a real running clock for the init sequencer, which
is HCLK. The generator writes `defparam CLK_PERIOD = 20` into that instance, so
it is expecting 20 ns. Tied low the PLL never initialises.

Each board owns its own copy, and that is deliberate. The generator writes into
whichever project is open and adds the files to that project's list, so a
shared copy referenced by two projects produces

```
ERROR (EX3794) : Duplicate module name 'Gowin_PLL'
```

the first time either is regenerated. Two copies cannot collide however often
either is regenerated; the cost is that a frequency change has to be made in
each, which is the right cost for something that has to be stated per board
anyway.

**2. Check the dual-purpose pin settings and the top module.** Those live in
`boards/<board>/impl/<project>_process_config.json`, not in `pins.cst`, and the
filename follows the project name. Two keys in it are identity rather than
settings -- `TopModule` and `OUTPUT_BASE_NAME` -- so copying another project's
config carries its identity too, and the symptom is

```
ERROR (EX0302) : No valid top module found
```

after every file has parsed cleanly. See `gw5a25/bench/README.md`, which
records this happening.

## The SoC config is currently shared

Each board has its own `mcu.yaml`, and `tools/check_project.py` reads each
board's own copy, but **the generated RTL is not per board**: `ahb_fabric.v`,
`m1core_apb.v`, the spliced regions of `m1core_mcu.v` and the BSP header are
written once, and `make checkgen` validates them against `gw5a25/mcu.yaml`.

So today all three boards must describe the same SoC -- same peripherals, same
TCM sizes, same `clock.hz`. They are identical files apart from a comment, and
they should be kept that way until the generator can emit per board.

That matters most for `clock.hz`, which is compiled into the BSP as a constant
and sets the uart baud divisor and the rtc prescale. If the megas turn out to
run meaningfully faster and you want to use it, per-board generated output is
the change that has to happen first. Measuring Fmax does not need it: the
constraint comes from the PLL and the sdc, not from `clock.hz`.
