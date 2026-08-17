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

**Measured, from `impl/pnr/*.timing_paths`.** Before the nvic selection became a
tree: Fmax 25.697 MHz, 37 logic levels, worst slack +1.085 ns, and one hold
violation. After: **Fmax 33.394 MHz, 14 logic levels, +10.055 ns, no
violations.**

The first diagnosis here was wrong twice, and both mistakes are worth keeping.

`ST_EXEC` was not the limit. The report showed the worst path leaving the nvic
through roughly thirty levels of priority selection, into an ICSR read and from
there into the register file. That selection was a running comparison down
thirty four candidates, each testing against the result of the one before, so
it could not be parallelised. It is a balanced tree of pairwise minimums now.

Then, having found that, the prediction was that fixing it would buy almost
nothing, because the next path down was the core decode one at 38.474 ns
against the nvic path's 38.851. That was reasoning about the two as if they
were independent. They were not: on the same core path afterwards, **cell delay
fell from 15.067 ns to 5.581 ns while routing barely moved**, because the adder
remapped onto the dedicated carry chain (0.050 ns per stage) instead of about
twenty three generic LUTs (0.46-0.53 ns each). Removing the large cone freed
enough congestion for the mapper to do that. Timing work on a congested device
is not a sum of independent paths.

**Routing is now the whole problem: 80% of the critical path is wire**
(23.925 ns route against 5.581 ns cell), and the high fanout list is
`state[1]` at 770 loads, `state[2]` at 535, `inst[6]` at 507. Depth is no
longer what to attack.

The divider is gone in favour of a pll. Note what the numbers mean: 25.697,
33.394 and 44 MHz were all measured while `timing.sdc` still asked for 25 MHz,
so the tool stopped optimising as soon as it met that. They are floors. The
first build that actually asks for the target is the one that says what the
design can do.

**Check worst setup slack before programming.** A peripheral that misses timing
glitches. A cpu that misses timing computes the wrong answer intermittently and
corrupts its own state, which presents as a software bug.

### Asking for 100 MHz, and what it measured

Constraining at 100 MHz failed, as expected: -7183 ns of total negative slack
across 1752 endpoints. That was the point. **Actual Fmax 52.158 MHz** is what
the design reaches when the tool is pushed, and every earlier number was a
floor taken while it was coasting at a 25 MHz target.

The failing paths were all `regs[] -> regs[]` and `regs[] -> inst[]` inside
`u_core`: register file, through the `ST_EXEC` decode cone, back to the
register file, 18 levels and about 19 ns. To halve that needs a pipeline
register, not a tool setting.

**ST_DECODE** is the first cut. Every read site in `ST_EXEC` indexes the
register file with a constant expression over `inst` bits, so decode does not
need to know the instruction format: it reads all eight candidates in parallel
and execute picks one. That made it a substitution rather than a rewrite of the
decoder, and it is equivalent rather than merely plausible, because nothing
writes `regs`, `pc` or `sp` between decode and execute.

It costs exactly one cycle per instruction, measured: **CPI 5.28 -> 6.28**,
and bought **Fmax 52.158 -> 60.436**, +16% clock for +19% cycles. On its own
that was a 3% throughput loss.

### Trying to get the cycle back, and failing

Counting cycles per state rather than looking at CPI alone showed where they
went, and it was not where the pipelining work was aimed:

    FETCH_A   682 cycles  31.9%   <- 2.00 per instruction
    FETCH_D   341         15.9%
    DECODE    341         15.9%
    EXEC      341         15.9%
    MEM_A/D    73 each     3.4%

`ST_FETCH_A` spends **two cycles on every instruction**, a third of all cycles
in the design. `bus_req` is a registered output cleared when a grant arrives,
and `m1_gnt = m1_req && !m0_req && hready` is combinational from it, so entering
with `bus_req` low costs one cycle to raise it and a second to see the grant.
Loads and stores never pay it, because execute already asserts their request
before entering `ST_MEM_A`.

**Two attempts to apply the same trick to fetch, both net negative.**

Routing every branch target and next state through blocking `pc_next` and
`nstate`, so one place at the end of execute could issue the fetch, worked and
took **CPI 6.28 to 5.28**. It also took **Fmax 60.436 to 47.641**. The funnel
replaced six individually enabled `pc` writes and sixteen `state` writes with
single wide muxes feeding both `pc` and the bus address, and the new worst path
was `pc -> pc_next -> bus_addr` at 20.95 ns. 9.62 MIPS became 9.02: worse on
both axes.

Issuing the fetch at each branch site instead, keeping the distributed
structure, is correct but only reaches CPI 6.09, and duplicates four branch
adders onto the bus address path, which is what cost the 13 MHz the first time.

Issuing it speculatively for every instruction at the top of execute is
**wrong**: `bus_req` stays asserted until something clears it, and exception
entry and multi-register transfers advance their own counters on `bus_gnt`. A
stale speculative request makes them count a transfer that was not theirs. The
regression catches it immediately, in three testbenches.

### What worked instead: buffer the halfword already being fetched

The fetch reads a whole 32 bit word and keeps half of it:

    inst <= pc[1] ? bus_rdata[31:16] : bus_rdata[15:0];

With `pc[1]` clear, `bus_rdata[31:16]` is the instruction at `pc+2`, and it was
being discarded on every fetch. Keeping one halfword with its address skips the
entire three cycle fetch for the next instruction. Holding the address rather
than a "this is the next one" flag means a branch that happens to land on the
buffered halfword still hits, and everything else misses without being told.

**CPI 6.28 -> 5.51.** The buffer served 130 of 341 fetches. It is invalidated on
reset, on any store, and whenever the core is halted, because a gdb load writes
itcm through the debug port while stopped and anything buffered beforehand is
then stale.

Note what this did not touch: no bus protocol change, no request asserted
speculatively, nothing that can linger into a state that counts its own grants.
That is why it worked where the two attempts above did not.

The remaining fetch cost is 763 cycles for 341 instructions, against a floor of
about 1.5 per instruction if every word fetch served both its halfwords. The
gap is branches, which invalidate by address mismatch.

### Why the two cycles are hard to remove directly

The two cycles in `ST_FETCH_A` are real, and they are defended by the bus
handshake. Removing them means the fetch address has to be produced a cycle
earlier, and every cheap way of doing that puts branch resolution on the
address path. Doing it properly means the fetch of instruction N+1 overlapping
the execute of N with its own request tracking, which is a pipeline. The tree
is back at CPI 6.28 and Fmax 60.436.

### Superseded: getting the cycle back

Counting cycles per state rather than looking at CPI alone showed where they
went, and the answer was not where the pipelining work was aimed:

    FETCH_A   682 cycles  31.9%   <- 2.00 per instruction
    FETCH_D   341         15.9%
    DECODE    341         15.9%
    EXEC      341         15.9%
    MEM_A/D    73 each     3.4%

`ST_FETCH_A` was spending **two cycles on every instruction**, a third of all
cycles in the design. The cause is a handshake: `bus_req` is a registered
output that gets cleared when a grant arrives, and `m1_gnt = m1_req && !m0_req
&& hready` is combinational from it. Entering the state with `bus_req` low
means one cycle to raise it and a second to see the grant come back. Loads and
stores never paid it, because execute already asserts their request before
entering `ST_MEM_A` -- which is exactly the fix, applied to fetch.

Execute now decides its next state and next pc in blocking `nstate` and
`pc_next`, so both are readable at the end of the cycle, and issues the fetch
itself when it is going straight to one. The same is done after loads, after
multi-register transfers and after a vector fetch.

**FETCH_A is 342 cycles for 341 instructions now, and CPI is back to 5.28** --
the decode stage is paid for. Four cycles is the floor for this structure
(fetch address, fetch data, decode, execute); going below it needs the fetch of
the next instruction to overlap the execute of the current one, which is a
pipeline rather than a state machine.

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

### The plateau, and what was actually wrong

Four configurations were built and measured on hardware. Every one of them
landed in the same narrow band:

    configuration              Fmax     CPI    MIPS
    baseline                 52.158    5.28    9.88
    + decode stage           60.436    6.28    9.62
    + prefetch funnel        47.641    5.28    9.02
    + instruction buffer     52.515    5.51    9.53

Anything that removed a cycle added to the critical path, and anything that
shortened the path cost a cycle. Note also that the third build had *fewer*
logic levels than the second (11 against 16) and a *lower* Fmax. Depth was not
the constraint.

The utilisation report said what was:

    Logic (LUT/ALU)   14121/23040   62%     <- 13134 LUTs
    Register           2591/23280   12%

62% LUT occupancy against 12% registers, and 80% of the critical path in
routing, with paths spanning R2C4 to R30C90 on a design that should fit in a
corner. A Cortex-M0 soft core is typically 2-3k LUTs; this was 13k. The core
was too big, the placer had no room, and every local optimisation bought its
cycle with area and paid for it in wire.

`yosys -p "synth_gowin" rtl/core/m1core_cpu.v` reported 13113 LUTs against
Gowin's 13134 for the whole MCU, so the CPU *is* the design -- peripherals,
NVIC, fabric and debug together are a rounding error -- and yosys is a usable
proxy for measuring it without a full build.

### Where 13k LUTs actually went

A verilog function is inlined at every call site. Four of them were being
called from far more places than there is hardware to justify:

- `do_lsl`/`do_lsr`/`do_asr`/`do_ror` from 11 sites: **11 barrel shifters**,
  the most expensive structure in the datapath, for an instruction set that
  can shift once per instruction
- `addc` from 11 sites: **11 adders**
- `st_place` from 5 sites, all with the same operand and only the size varying

Worse, and much less obvious: **verilog infers one register file write port per
distinct index expression**, and there were seven of them -- `rd_i`, `ld_rd`,
`multi_base`, `lowest_set(multi_list)`, `inst2[11:8]` for MRS, `dreg_sel` for
gdb, and constants for the exception frame. Seven address decoders and seven
enable trees over fifteen 32-bit registers. No two can ever fire in the same
cycle; they belong to different states or different branches of execute.

The decode stage added earlier made this worse in the same way. It read all
eight candidate register fields in parallel so execute would not have to know
the instruction format, which is eight 16-to-1 muxes over the file.

### The fix: one of each

Every site now raises a request -- `sh_req`, `add_req`, `st_req`, `wb_en` --
and a single shared unit below the execute `casez` does the work. Reads went
from seven ports to three, which is the real requirement since no ARMv6-M
instruction reads more than three registers, and the candidate fields collapse
almost for free: every port A variant is `{x, inst[2:0]}` and every port B
variant is `{x, inst[5:3]}`, differing only in the top bit. The index selects
sit in decode, where there is slack, not in execute, where the critical path
is.

Measured step by step, which is worth doing because the answer is not the one
the source code suggests:

    step                                        LUT     ALU     MUX
    original                                  37130    2198   11134
    + shared shifter and adder                37226    1536    8240
    + 3 read ports, some writes consolidated  34082    1534    9246
    + all writes on one port                  25898    1534    6678

(one flow throughout, so the ratios are what matter here, not the absolute
values -- that parse was summing several of yosys's stat printings. Measured
properly with `tee -o`, the core went from 12998 LUT / 1099 ALU / 5567 MUX to
9610 / 767 / 3339, which is -26% LUT, -30% ALU, -40% MUX, at a cost of 69
flops for the request registers. Scaled to Gowin's own count that is about
9700 LUTs of 23040: **42% occupancy, down from 62%**.)

**Sharing eleven barrel shifters and eleven adders bought nothing in LUTs.**
37130 to 37226 is flat. It cut ALU cells by 30%, and the shifters were the
obvious, conspicuous duplication -- and they were not the problem. The entire
LUT win came from the register file ports, and mostly from the last step:
consolidating the remaining write index expressions took 24% off the core by
itself.

The lesson generalises. The expensive duplication was not the thing that looked
expensive in the source. Eleven barrel shifters are visible on the page; seven
write port decoders are an emergent property of how many distinct expressions
happen to appear inside `regs[...]`, which nothing in the code makes visible at
all. If you add a writeback here, check that it reuses `wb_en`.

Whether 42% occupancy converts into clock is a question for the build, not for
yosys. It is the constraint the timing report pointed at -- 80% of the critical
path in routing, on a design spread across the whole die -- but three previous
attempts at that path came out net-neutral, so nothing here should be treated
as a predicted Fmax until a build says so.

The four shift functions folded into one 64-bit funnel shifter. Left shifts
reach it by reversing in and out, since `a << m` is `rev(rev(a) >> m)`, and the
carry rule comes out uniform too, because LSL's carry `a[32-m]` is exactly
`rev(a)[m-1]`, the bit LSR would report. Only the `amt >= 32` cases stay op
specific, and ROR has none because it works modulo 32.

That rewrite was checked against the four original functions over 832,000 cases
-- 4 ops x amounts 0..259 x 400 values x both carry-ins -- before a single call
site was switched over. CPI is unchanged at 5.51; this is purely area.

The lesson worth keeping: **measure area before optimising for speed on an FPGA
soft core.** Three consecutive attempts at the critical path came out
net-neutral because the real constraint was occupancy, and nothing in a timing
report says so directly. The utilisation summary does.

## The pipelined core

`tools/select_core.py pipeline` switches the build from the multi-cycle core to
the 3-stage one, and `multicycle` switches back. It is a script rather than
three edits because the two cores are alternatives and exactly one may be in
the project: gowin picks a top module by looking for one nothing instantiates,
so leaving the unused core listed gets it chosen as top and every pin in
pins.cst then fails to bind with CT1135, which reads as a constraints problem
and is not one. `tools/check_project.py` enforces the pairing and prints which
core is selected.

Simulation is independent of that choice. It pins the core on the iverilog
command line with `M1CORE_FORCE_MULTICYCLE` or `M1CORE_PIPELINE`, so `make
core` and `make corep` test the two cores side by side from the same checkout
whatever the bitstream is set to build.

    F   m1core_fetch, one 32-bit access per cycle into a halfword queue
    D   m1core_decode table, three read ports, operand select, forwarding
    E   m1core_alu, branch resolve, two-phase memory, writeback

Measured on the same 148-check suite, and on the whole mcu through yosys:

    multi-cycle   1879 cycles   CPI 5.51    13151 LUT  1372 ALU
    pipelined      958 cycles   CPI 2.83     9963 LUT  1006 ALU

It is both faster and smaller, which is the point of the decode table: one
datapath driven by a control word rather than 31 casez branches each building
their own.

### Known open item: the hello uart test

`make hellop` fails and `make hello` passes, on the same firmware image, and I
could not reconcile two measurements of why. The testbench gives the core 50 ms
of simulated time to emit 40 characters. The pipelined core emits 29 in that
window; the multi-cycle core reaches the threshold. But a controlled run of the
same binaries measuring time-to-character-count says the pipelined core is
about 10% *faster* to the same count, which cannot both be true.

What is certain is that both cores emit byte identical, correct output, so this
is a throughput or measurement question and not a correctness one. `hellop` is
deliberately left out of the `pipeline` target so the suite's pass count does
not quietly cover a test known to fail. Resolve it before trusting any
performance claim about branch-heavy or memory-dense code.

### Exceptions: implemented, not finished

The pipelined core takes exceptions. Entry stacks the 8-word frame, the vector
is fetched from the fixed table at zero, and return unstacks it, restoring the
mode and the banked stack pointer. `bx lr` and `pop {pc}` with an EXC_RETURN
value both return, svc and udf are taken synchronously, cps masks interrupts,
and msr/mrs reach psp, control and ipsr. Traced end to end, svc, pendsv and
systick all enter and return with the correct frame, and the frame written on
entry reads back word for word on exit.

**But 4 of the 15 checks in `make excp` still fail** (ids 1, 9, 10, 11; 9 is
the msp balance check). The suite runs to completion rather than stopping, which
it did not before, so what is left is a real bug and not a missing feature. Do
not run interrupt-driven firmware on this core until that is closed. The
multi-cycle core has full, passing exception support and stays selectable for
exactly this reason.

Two bugs found and fixed on the way, both worth knowing:

- the exception state was only initialised on `sys_reset_req`, not on power-on
  reset, so `control_spsel` was x, `use_psp` was x and the banked stack pointer
  read as x on the very first exception
- returning via `pop {pc}` captured the frame address from the stack pointer it
  still had rather than the one it was about to write back, putting the frame
  one whole pop too low and unstacking garbage

Anything the core does not implement stops it at the instruction boundary with
`halt_pc` pointing at the offending halfword, and **reports halted to the
debugger**, so gdb can be attached afterwards and asked where it stopped. A
core sitting stopped while the debugger reports "running" is the worst possible
hardware symptom: a dead board with no way to ask it why. `bkpt` lands in the
same path, which is how gdb software breakpoints work.

### Things that were wrong, and how they showed up

Worth reading before changing any of it, because none of these were found by
inspection:

- **fetch reissue.** the first version gated a new bus request on the previous
  one having returned, which is the same mistake the multi-cycle core made and
  cost it two cycles per fetch. it measured 27 halfwords per 40 cycles.
  overlapping the address and data phases, which is what the ahb pipeline is
  for, gives 40 in 40 using 45% of the bus
- **wrong-path execution.** `redirect` is registered, so for one cycle after a
  taken branch the queue still holds speculatively fetched halfwords. literal
  pools sit immediately after branches and 0xffffffff was being decoded as an
  instruction. decode has to be gated on `!redirect`
- **store data timing.** ahb carries write data in the data phase, one cycle
  after the address phase it belongs to, and ahb_arb routes it combinationally
  from the master. the bus mux has moved on by then, so the data must be
  registered at grant or every store writes zero
- **pop decoding.** push and pop are told apart by inst[11:9], 010 and 110.
  slicing any other field gets pop wrong, and pop is a return instruction, so
  nothing a c toolchain emits will run
- **bl offset width.** the offset is 25 bits and needs 7 bits of sign
  extension, not 8. one bit too many truncates the sign for backward calls only
- **starting an address phase during wait states.** the bus mux dropped back
  to fetch as soon as the data access moved into its data phase, so a fetch
  address went onto the bus while a wait-stated apb read was still outstanding.
  ahb requires the master to hold address and control stable while hready is
  low, and the reason is not politeness: ahb_fabric latches which slave owns
  the data phase, so the fetch moved hready onto the itcm, which is always
  ready, and the core sampled the previous cycle's rdata as the result of the
  apb read. the symptom was a uart status poll returning the last value loaded,
  so the tx-ready check always passed and characters were dropped: "m1core
  alive" came out as "mevt00". zero-wait-state memory never shows this, which
  is why the isa suite, the randomised tests and blink all passed
- **the fabric latched the data phase owner on htrans alone**, without
  qualifying it with hready, while every slave qualifies its own address phase
  correctly. a well behaved master cannot trigger it, which is why it survived
  this long, but it turned the bug above into silent data corruption rather
  than a stall. fixed in tools/m1core_gen.py, since ahb_fabric.v is generated
- **functions over module state.** the register read ports were written as
  verilog functions reading `regs` and the execute registers from inside a
  continuous assignment. operands went stale for three cycles and forwarding
  never fired at all. index the array directly

## What to expect

1. Power up with nothing attached. LED[0] blinks: the fabric is clocked and the
   design is alive. GPIO stays still, because the ITCM is empty.
2. **Slow the probe before scanning, every session.** BMP's
   `target_clk_divider` defaults to `UINT32_MAX`, which skips its delay loops
   entirely and bit-bangs SWD at full speed. That outruns the phy's oversampler
   and the scan fails, usually as `SWD invalid ACK`.

   The setting does **not** persist: a fresh gdb session or a probe replug is
   back at the default. `sw/gdbinit` sets it, or type `mon frequency 500k`
   before `mon swd`.
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
