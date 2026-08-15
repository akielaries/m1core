# Tang Primer 25K build

`GW5A-25`, part `GW5A-LV25MG121NES`. Layout follows the ACM convention: shared
board-independent RTL in `rtl/`, and everything physical in here. A second board
is a new directory and nothing else.

## Build

Open `m1core.gprj` in the Gowin IDE, synthesise, place and route, program.

Firmware arrives over SWD via `gdb load`, so nothing has to be built first.

### Optional: preload the ITCM

`ITCM_INIT` in `top.v` is empty by default and the ITCM comes up zeroed. Setting
it makes the board run firmware at power-up with no probe attached, which is a
good bring-up signal, but an unresolvable `$readmemh` path is a **hard synthesis
error**, not a soft fallback, and the directory GowinSynthesis runs from is not
worth guessing at. To enable it:

```
cd ../../sw/baremetal && make
cp apps/blink/build/blink.hex ../../boards/gw5a25/
```

then set `ITCM_INIT` to `"blink.hex"` in `top.v`, and adjust the path if
synthesis cannot find it.

## Language

The RTL is plain **Verilog 2001**, deliberately.

The first build attempt was SystemVerilog and GowinSynthesis rejected it
wholesale: `logic is an unknown type`, `Verilog 2001 keyword 'begin' used in
incorrect context`, and so on for every file. There is a `Verilog_Standard`
setting in `impl/<project>_process_config.json` (it defaults to `Vlg_Std_2001`)
that can be switched to SystemVerilog in the IDE, but chasing it is not worth it:
Gowin's SystemVerilog frontend is partial, and a partial frontend that
*miscompiles* is a far worse problem than one that refuses to parse.

So the design was down-converted: `logic` became `reg`/`wire`, `always_ff` and
`always_comb` became `always @(posedge ...)` and `always @(*)`, the state
`typedef enum`s became `localparam` blocks, and typed parameters lost their type
keywords. The regression suite passed unchanged before and after, which
is what made a mechanical refactor of this size safe to do at all.

The RTL now parses under `iverilog -g2001` in strict Verilog-2001 mode and under
yosys `read_verilog` without `-sv`. Keep it that way — if you add RTL, check it
with:

```
iverilog -g2001 -Wall -t null rtl/core/*.v rtl/debug/*.v rtl/periph/*.v \
    rtl/mcu/*.v boards/gw5a25/top.v
```

The testbenches under `tb/` are still SystemVerilog. That is fine and
intentional: they never go near Gowin.

## Dual-purpose pins (required, or placement fails)

Several balls on this device default to a dedicated configuration function and
have to be explicitly released before they can be used as regular IO. Without
that, place and route fails with:

```
ERROR (PR2017) : 'HCLK' cannot be placed according to constraint,
                 for the location is a dedicated pin (CPU/SSPI)
ERROR (PR2017) : 'LED[1]' cannot be placed according to constraint,
                 for the location is a dedicated pin (I2C)
```

This setting does **not** live in `pins.cst`. It is project configuration, in
`impl/m1core_process_config.json`, or in the IDE under
**Project > Configuration > Place & Route > Dual-Purpose Pin**.

Required here, matching the ACM gw5a25 build that places successfully on this
same board:

| Option | Value | Why |
| --- | --- | --- |
| CPU | true | frees E2 for HCLK |
| SSPI | true | E2 is shared CPU/SSPI |
| I2C | true | frees B2 for LED[1] |
| **JTAG** | **false** | leave it alone |

Note the filename follows the project name, so renaming the `.gprj` orphans
these settings and placement fails with PR2017 again until they are set on the
new file.

**Never enable JTAG as regular IO on a Gowin part.** It takes the programming
pins away and you lose the ability to reprogram the board.

The values are already set in the checked-in config. One caveat: if the project
is open in the IDE while you edit that JSON, the IDE may write its own copy back
over yours on save. Either close the project first, or just set the four options
through the GUI.

## Pins

Ball locations are reused from the ACM gw5a25 build, which already works on this
board. Verify them in the IDE anyway.

| Signal | Ball | Notes |
| --- | --- | --- |
| HCLK | E2 | 50 MHz onboard, needs CPU+SSPI released |
| HRST | H10 | key, **active high**, pulled down |
| SWCLK | G5 | |
| SWDIO | F5 | **must be pulled up** |
| LED[0] | C11 | onboard, heartbeat. confirmed blinking |
| LED[1] | C10 | pmod, SWCLK edges seen at the pin |
| LED[2] | B11 | pmod, line reset recognised (sticky) |
| LED[3] | B10 | pmod, valid packet decoded (sticky) |
| GPIO[0] | D11 | pmod, firmware controlled, blink toggles this |
| GPIO[1] | D10 | pmod, firmware controlled |

LED[1..3] and GPIO were moved onto a contiguous PMOD block so they are reachable
with a single connector. Since LED[1] is no longer on B2, the `I2C` dual-purpose
option is not strictly required any more; it is harmless to leave enabled, and
`CPU`/`SSPI` are still needed for the clock on E2.

SWCLK and SWDIO are still on G5/F5, which are not on that PMOD block. Moving them
onto the same connector is fine, and probably easier to wire: keep both on the
same bank, keep SWDIO pulled up, and rebuild.

SWD is only two wires, so move them to wherever suits your probe lead. Keep both
on the same bank and keep SWDIO pulled up: the bus is undriven during every
turnaround, and the framer relies on reading that as a one to swallow the
trailing turnaround clock.

The reset polarity is inherited from this board's convention, active high with a
pull-down so it boots without the key held. `top.v` inverts it for the MCU, which
takes an active-low reset. If the board comes up stuck in reset, the key idles
high and that inversion needs flipping.

## Clock: 50 MHz divided to 25

`top.v` divides the 50 MHz oscillator by two and runs the MCU at 25 MHz.

The first build met timing at the full 50 MHz, but with **0.023 ns of slack**,
and all 50 reported paths sat under 0.5 ns. The critical path runs from an
instruction bit through roughly 17 levels of decode logic straight into the
register file write port: `ST_EXEC` is one enormous combinational `casez` over
the whole instruction set, and every branch's result muxes into the same write
port. Margin that thin is not worth trusting across voltage and temperature, and
any RTL change flips it negative.

Halving the clock costs nothing that matters yet. The core is multi-cycle, so
this only halves an already modest instruction rate, and 25 MHz is still 5x a
typical probe's SWD clock, comfortably inside the phy's "at least 4x SWCLK"
requirement.

The real fix is to register the decode so `ST_EXEC` stops being a single
combinational cone. Once that is done the divider can come out.

`timing.sdc` deliberately does **not** declare SWCLK as a clock. The phy
oversamples it and detects edges, so it never reaches a register clock pin and
there is no second clock domain. Declaring one would invent a domain that does
not exist and generate meaningless cross-domain paths.

It declares `clk_sys`, the HCLK/2 the MCU actually runs on, as a generated
clock. Without that the tool has no description of it and invents a
relationship: a build reported `required = 12.9 ns` on a path between two
`clk_sys` registers, which is neither the 20 ns nor the 40 ns period and is not
a number worth acting on.

It is otherwise kept minimal. An earlier version added
`set_false_path` constraints and the tool emitted a 337-byte, empty
`m1core.tr.html`, which is what a rejected SDC looks like. **After a build, check
that `impl/pnr/m1core.tr.html` actually has content.** If it is near-empty the
timing constraints are not being applied and any slack number is meaningless.

## What to expect

1. Power up with nothing attached. LED[0] blinks: the fabric is clocked and the
   design is alive. GPIO stays still, because the ITCM is empty.
2. **Slow the probe before scanning.** BMP's `target_clk_divider` defaults to
   `UINT32_MAX`, which skips its delay loops entirely and bit-bangs SWD at full
   speed. The phy oversamples SWCLK and needs the system clock to be at least 4x
   it; at 25 MHz that caps SWCLK around 6 MHz, and BMP's default is likely above
   that. `mon frequency 500k` first, raise it later once things work.
3. Attach the probe and read the LED staircase (see `m1_mvp_top.v`):
   LED[1] = SWCLK arriving, LED[2] = line reset recognised, LED[3] = valid packet
   decoded. Each only happens if the previous did, so the first dark one is where
   to look.
4. `monitor swd_scan` should print a Cortex-M1, on **stock** BMP.
5. `attach 1`, then poke the GPIO directly to prove the debug path end to end
   with no CPU involved:
   ```
   set *(unsigned*)0x40000004 = 3     # dir, both outputs
   set *(unsigned*)0x40000008 = 1     # led on
   set *(unsigned*)0x4000000c = 1     # led off
   ```
6. `load ../../fw/build/blink.elf`, then `continue`. GPIO[0] should blink on its
   own, which means the core is fetching and executing.

Steps 5 and 6 fail differently and that is useful: 4 failing points at the debug
path, 5 failing at the core.
