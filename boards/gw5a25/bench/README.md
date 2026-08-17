# benchmarking against gowin's empu m1

Every Fmax number in `HANDOFF.md` is relative to itself. This project answers
the one question the reports cannot: **what does a known good ARM core reach on
this exact part, at this speed grade, with this toolchain?**

That number decides whether 100 MHz is an engineering target or a wrong target.

## Do not program the device

Build it, read the report, stop. Two reasons:

- The eMPU's `JTAG_7` / `JTAG_9` are its debug pins. If the tool places them on
  the dedicated JTAG balls it will want **JTAG as regular IO**, and
  `boards/gw5a25/README.md` records what that costs: the board stops being
  reprogrammable. Synthesis and place-and-route produce the timing report
  without ever loading a bitstream, and the report is all we want.
- Nothing here is a working system. It is a harness for a measurement.

## Why it is a separate project

`Gowin_EMPU_M1_Top` was added to `m1core.gprj`. That has to be undone before
the next m1core build: Gowin picks a top module by looking for one that nothing
instantiates, and with the IP sitting in the project unreferenced it becomes a
candidate alongside `top`. The symptom is every pin in `pins.cst` failing to
bind with `CT1135`, which looks like a constraints problem and is not one. It
is the same trap `tools/select_core.py` exists to avoid for the two cpus.

So: build `bench/empu_bench.gprj`, and keep `m1core.gprj` free of the IP.

## Each project owns its own PLL

`boards/gw5a25/src/gowin_pll/` belongs to `m1core.gprj`.
`boards/gw5a25/bench/src/gowin_pll/` belongs to `empu_bench.gprj`.

They are byte-identical today and both are the same 100 MHz, but they are
separate copies on purpose. Regenerating the PLL from the IP Core Generator
writes into the `src/` directory of whichever project is open, and the IDE then
adds those files to that project's file list. With one shared copy referenced
by both, the first regeneration produces:

```
ERROR (EX3794) : Duplicate module name 'Gowin_PLL'
ERROR (EX3794) : Duplicate module name 'Gowin_PLL_MOD'
ERROR (EX3794) : Duplicate module name 'PLL_INIT'
```

because the project ends up listing the new copy and the old one. Two copies,
each referenced only by its own project, cannot collide however many times
either is regenerated. The cost is that a frequency change has to be made
twice, which is the point: the comparison is only meaningful if both are asked
for the same clock, and that is now an explicit act rather than an assumption.

**Both must be 100 MHz for the numbers in the table below to mean anything.**
The current pair is `MDIV 14 / ODIV0 7`, VCO 700, one output. The `82.009` in
the table was measured through `MDIV 18 / ODIV0 9`, VCO 900, two outputs --
same 100 MHz by a different route, which is worth knowing if a rebuild moves by
a fraction of a percent.

The eMPU IP itself stays in `../src/gowin_empu_m1/` and is referenced by this
project only. If it ever reappears in `m1core.gprj`, `tools/check_project.py`
fails the build and says why: nothing instantiates it there, so Gowin can pick
`Gowin_EMPU_M1_Top` as the top module instead of `top` and every pin in
`pins.cst` then fails with `CT1135`.

## The project config is copied, and two keys in it are identity

`bench/impl/empu_bench_process_config.json` started as a copy of
`impl/m1core_process_config.json`, because the dual-purpose pin settings live
there and nowhere else: `CPU` and `SSPI` true to free E2 for HCLK, `I2C` true,
and **`JTAG` false, always** -- releasing JTAG as regular IO costs the ability
to reprogram the board.

Copying it wholesale drags across two keys that are not settings but names:

```
"TopModule"        : "top"      ->  "empu_bench_top"
"OUTPUT_BASE_NAME" : "m1_soc"   ->  "empu_bench"
```

Left alone, the first one produces `ERROR (EX0302) : No valid top module
found`, after every file has parsed cleanly, because the bench project has no
module called `top`. The error points at the rtl and the cause is in the json.

This is the same hazard `../README.md` records for renaming a `.gprj`: the
config filename follows the project name, so these settings are per project and
copying one project's config into another carries its identity too.

The other 89 keys must stay identical, because the benchmark is only a
comparison if both projects are given the same job. The clock is the half
everyone checks; the place and route options are the half that is invisible,
and the ide rewrites that json whenever it feels like it. Run:

```
python3 tools/check_bench_config.py
```

It passes when the two configs agree on everything except `TopModule` and
`OUTPUT_BASE_NAME`, and names the key when they do not.

Note what it currently reports: **`Place_Option 2, Route_Option 1`**. The bugs
list in `HANDOFF.md` says to leave the place and route options at defaults, and
names `Place_Option 2/3` and `Route_Option 1/2` as the values that produced
unroutable designs or a five hour routing phase. Both projects are on two of
those values. Either they were set once and never reverted, or those are the
ide's defaults for this device and that entry is describing a different
numbering -- check what the ide offers as default before trusting either
reading. It is a candidate explanation for m1core's build time, and it is
applied equally to both projects, so it does not bias the comparison.

## Pins

There is deliberately no `.cst`. Let the tool place the ports; for a timing
run, pin choice is noise, and guessing balls on this board is how `PR2017` and
`CT1135` happen. `../timing.sdc` is shared, so the 50 MHz pin is constrained
the same way and the 100 MHz PLL output is derived from the PLL's own
parameters in both projects.

## What to record

From the eMPU build's `impl/pnr/*.rpt.txt` and the timing report:

**Result, both built on GW5A-LV25MG121NES ES, same toolchain, same pll, same
100 MHz constraint, same sdc:**

| | m1core (round eleven) | Gowin eMPU M1 |
| --- | --- | --- |
| **Actual Fmax, pll clock** | **81.691 MHz** | **82.009 -> 87.724 MHz** |
| Logic Level | 12 | 9 |
| Setup violated endpoints | 1228 | 1644 |
| Setup TNS | -929.177 | -1549.223 |
| Logic | 8375 / 23040, 37% | 6504 / 23040, 29% |
| CLS | 5196 / 11520, 46% | 4931 / 11520, 43% |
| Register | 3245 / 23040, 15% | 3294 / 23040, 15% |
| BSRAM | 41 / 56, 74% | 33 / 56, 59% |
| DSP | 4 / 28 | 4 / 28 |
| ITCM / DTCM | 32 KB / 16 KB | `ITCM_Size=5`, `DTCM_Size=5` |

### The second eMPU build, and a confounded experiment

The eMPU was rebuilt and came back at **87.724 MHz**, up from 82.009. That is
7%, and it is not dismissible as placement noise.

It is also **not attributable**, because two things changed between those two
builds:

- the pll went from two outputs to one, and from `MDIV 18 / ODIV0 9` (VCO 900)
  to `MDIV 14 / ODIV0 7` (VCO 700) -- same 100 MHz by a different route
- `bench.cst` did not exist for the first build, so `HCLK` was auto-placed;
  it is pinned to E2 now

One variable at a time. The clean version of this experiment is **rebuilding
m1core**, because `pins.cst` has always pinned `HCLK` to E2, so the pll is the
only thing that changes. If m1core moves from 81.691 to about 87, it is the
pll, and the same gain should be assumed for any future comparison. If it does
not move, the gain was the pin or the placer, and that finally gives this
project the build-to-build noise figure it has never measured.

Until that rebuild, **the two cores are not comparable** and the standing is
unknown rather than 82 vs 88.

### The 283 hold violations are ours, not theirs

Every one of them is `JTAG_9_ibuf -> ...uSyncBusReq/sync_reg`,
`...Buscnt_cdc_check`, `...TaReg_cdc_check`. Those are ARM's own clock domain
crossing synchronisers between the debug port and the core clock, and the
register names say so.

They appear because `../timing.sdc` declares `HCLK` and nothing else, so the
tool invented a base clock on the JTAG pin -- it is in the Clock Summary as
`JTAG_9, Base, 100.000 MHz` -- and then timed an asynchronous crossing against
the core clock. It is the same class of artefact as the two `rst_sync` removal
slacks, and a real design would false-path it. It says nothing about their core
and it does not affect the Fmax number, which is on the pll clock.

### What their critical paths say about ours

Worth reading, because they are the same family:

```
u_itcm/mem0_...        -> u_r_bank/reg_file_b_..._RAMREG_13
u_r_bank/rptr_b_ex_3   -> u_dtcm/mem3_..._REDUCAREG
```

Tightly coupled memory read data into the register file, and the register bank
out to memory. That is exactly what rounds seven through eleven were fighting,
which is independent confirmation that the analysis was pointed at the right
thing.

Note `reg_file_b_..._RAMREG`: **their register file is in RAM, not flops.**
Round eleven identified the flop-based file's write fanout -- fifteen 32-bit
banks the placer spread across the die -- as a suspect, and this is evidence
that the alternative is what a production core does here.

**Fill in the TCM row from the IDE, in kilobytes.** The generated
`gowin_empu_m1.ipc` says `ITCM_Size=5` and `DTCM_Size=5`, but those are
dropdown indices, not sizes. BSRAM pressure is the current hypothesis for
m1core's placement problem — 74% of the block rams, in fixed columns, pulling
the logic apart — so a comparison that does not control for memory size tells
us nothing about it.

## How to read the answer

- **eMPU comes in near 100 MHz or above.** The part can do it, and the gap is
  ours to close. Its BSRAM number then says whether memory placement is the
  reason or an excuse.
- **eMPU comes in near ours, ~80 MHz.** 100 MHz is not available on a
  `GW5A-LV25MG121NES` engineering sample at this speed grade, whatever the
  datasheet marketing says, and the target should move to something the part
  supports. This is the outcome that would retire the goal rather than the
  work.
- **eMPU is much faster with far less BSRAM.** Shrinking the TCMs moves from a
  guess to the obvious next build.

Two things that favour the eMPU and are not design flaws in m1core: their core
arrives as an encrypted netlist already mapped and optimised for this family,
while ours is RTL the tool sees fresh; and their SoC has GPIO and one UART,
where ours also carries a timer, an RTC, an SPI and an I2C, all on the bus.

## The number that actually matters

Fmax is half of it. m1core is at **CPI 3.09**, so 81.7 MHz is about 26 MIPS. A
Cortex-M1 runs nearer CPI 1.5-2 on the same kind of code, so even at an equal
clock it would be roughly twice the throughput. If the eMPU build comes back
fast *and* we already know its CPI advantage, the honest conclusion may be that
the remaining headroom in this project is in CPI, not in megahertz — which is
where `HANDOFF.md` said the alternative was, back at the start.
