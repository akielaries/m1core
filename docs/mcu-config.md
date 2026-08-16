# MCU configuration and generation

How m1core gets configured: which peripherals exist, where they live, and which
interrupt each one owns. This is the scaffolding that makes peripherals cheap to
add and makes a configurator GUI a thin layer rather than a rewrite.

## The core argument: generate, don't parameterise

There are two ways to make an MCU configurable.

**Parameterise.** One `m1core_mcu.v` with `HAS_UART`, `HAS_SPI`, `NUM_GPIO`
parameters and `generate` blocks around every instance. This is where these
projects usually end up, and it rots: the fabric decode becomes a nest of
conditionals, the address map is implicit in the RTL, adding a peripheral edits
five files, and the C header drifts from the hardware.

**Generate.** Describe the MCU as data, and emit the RTL. Gowin's own IP
configurator works this way, which is the tell: it does not ship one mega-module
with a hundred parameters, it writes you a wrapper.

m1core generates. The consequences are worth being explicit about:

- The address map lives in **one** place and the RTL, the C header and the docs
  are all derived from it, so they cannot disagree.
- Adding a peripheral is a few lines of config plus a self-contained block.
- The generated top is plain readable Verilog you can diff, check in, and hand to
  someone with no generator installed.
- A GUI becomes a form that writes YAML. That is a weekend. Building the GUI
  first, before the config format exists, means hardcoding assumptions into it
  and then rewriting it.

**So: config schema and CLI generator first, GUI last.** The GUI is the cheap
part once the data model is right, and the expensive part if it is not.

## Two layers, two tools

There is a clean split, and conflating the two is what makes these systems
unpleasant:

| Layer | Question it answers | Tool |
| --- | --- | --- |
| Registers *within* a peripheral | what bits does UART0's CTRL have | Cheby |
| Composition *of* the MCU | is there a UART0, at what base, on which IRQ | m1core generator |

Cheby is already in use for the ACM register maps and emits both an RTL register
block and a C header from one YAML. That is exactly the right tool for the inner
layer, and reusing it means peripheral authors have one familiar workflow.

The outer layer is much simpler: a list of instances with a base address, an IRQ
number, and a handful of options.

## Bus structure

```
                 +-------------+
   m1core_cpu ---|             |--- ITCM      (AHB, zero wait state)
                 |  AHB fabric |--- DTCM      (AHB, zero wait state)
   MEM-AP     ---|             |--- PPB       (AHB, scs/rom table)
                 +-------------+--- AHB2APB --+-- UART0   (APB)
                                              +-- SPI0    (APB)
                                              +-- I2C0    (APB)
                                              +-- GPIO0   (APB)
```

Memory and the debug PPB stay on AHB, where zero wait states matter. Everything
else goes behind an AHB-to-APB bridge. Three reasons:

1. **Timing.** Every AHB slave widens the fabric decode and the read mux, and
   that mux already feeds the path nearest the timing limit. Peripherals behind a
   bridge cost the AHB fabric exactly one slot no matter how many there are.
2. **Peripherals get simpler.** APB has no pipelined address/data phase. A
   peripheral is a register file with a strobe. That matters when the point is
   for other people to drop blocks in.
3. **It is the conventional Cortex-M structure**, so it matches what anyone
   coming from an STM32 or a Gowin eMPU expects, and it matches the
   `apb_ahb_bridge.v` already in the AFM project.

## Interrupt numbering

The IRQ map deliberately follows Gowin's eMPU M1 where the peripherals
correspond:

| IRQ | Source |
| --- | --- |
| 0 | UART0 |
| 1 | UART1 |
| 2 | TIMER0 |
| 3 | TIMER1 |
| 4 | GPIO0 |
| 6 | RTC |
| 7 | I2C |

Same reasoning as the CoreSight ID contract: matching an existing convention
costs nothing and buys compatibility. m1kern already targets these numbers, so
its target layer ports with almost no change.

Unused IRQ lines tie low. The NVIC is sized to the highest number in use.

## Config format

One file describes an MCU instance:

```yaml
mcu:
  name: m1core_tang25k
  cpu:
    itcm_kb: 16
    dtcm_kb: 8
  peripherals:
    - { type: uart, name: uart0, base: 0x40000000, irq: 0, baud: 115200 }
    - { type: gpio, name: gpio0, base: 0x40001000, irq: 4, width: 8 }
    - { type: spi,  name: spi0,  base: 0x40002000 }
```

From that, the generator emits:

- `m1core_mcu_gen.v` — the APB decoder, peripheral instances, IRQ vector
- `m1core_mcu.h` — base addresses, IRQ enum, matching the CMSIS layout m1kern
  expects
- `memory-map.md` — the same information for humans

Peripheral register definitions stay in Cheby YAML per block, so the generator
never needs to know what is inside a UART.

## How the generator gets built safely

The first job of the generator is not to enable a new peripheral. It is to
**reproduce the MCU that already exists**, byte for byte where practical:

1. `boards/gw5a25/mcu.yaml` describes the current design, nothing more.
2. The generator emits the C device header from it. Diff against the
   hand-written `sw/baremetal/bsp/m1core.h`. They must agree.
3. Then `docs/memory-map.md`, same check.
4. Then the RTL: the APB decode and peripheral instantiation currently written
   by hand in `m1core_mcu.v`. Diff against what is there now, and the whole
   regression must still pass against generated RTL.
5. Only then add a peripheral that does not exist yet.

**Steps 1 to 4 are done.** `tools/m1core_gen.py` emits the C device header, the
generated section of `docs/memory-map.md`, and `rtl/mcu/m1core_apb.v`. All three
are checked by `make checkgen`, which runs as part of the regression, so a hand
edit to any of them fails locally.

## What is generated, and what is not

Adding an APB peripheral is four lines of `mcu.yaml`. Regenerating produces its
address decode, its slot in the read data and ready mux, its entry in the
interrupt vector, its instantiation, its base address and IRQ number in the C
header, and its row in the memory map. Verified by adding a second UART and
reading the diff.

The pins now propagate through `m1core_mcu.v` too, so the only edit left is the
board layer: a physical ball in `pins.cst` and one line in `boards/*/top.v`.
That part is irreducible — something has to decide which pin a signal comes out
of, and only the board knows.

`m1core_mcu.v` is **not** generated wholesale. Of its 440 lines, about fifteen
depend on the peripheral list: the external pin ports, and the pin connections
on the APB instance. Those sit between markers and are generated; everything
else — the CPU, the debug access port, the arbiter, the fabric, the memories,
the bring-up LEDs — is ordinary hand-written Verilog.

That split is deliberate. Generating the whole file would mean moving four
hundred lines of perfectly good RTL into Python string literals, where it is
harder to read, harder to edit, and no more correct. Generate what varies.

The generated port block uses leading commas:

```verilog
  output wire [GPIO_WIDTH-1:0] gpio
  // BEGIN GENERATED periph-ports
  , input  wire        uart0_rxd
  , output wire        uart0_txd
  // END GENERATED periph-ports
);
```

Slightly unusual, but it means a configuration with no APB peripherals at all
still produces a legal port list rather than a dangling comma.

Reproducing something known-good is a checkable milestone. Generating something
new is not — if the output is wrong you cannot tell whether the generator or the
new block is at fault.

## Order of work

1. **AHB-to-APB bridge**, and a written peripheral contract. Structural, and
   everything else assumes it.
2. **UART on APB.** The first real peripheral, and the thing that proves the
   contract end to end. Also the most immediately useful: printf beats an LED.
3. **Generator**, once there are two peripherals to compose and the shape of the
   problem is known from real examples rather than guessed at. *Done for the C
   header:* `tools/m1core_gen.py` emits `sw/baremetal/bsp/m1core.h` from
   `boards/gw5a25/mcu.yaml` plus the per-type layouts in `tools/peripherals/`.
   `make checkgen` fails the regression if the two ever disagree.
4. **Exceptions and NVIC.** The gate to m1kern and to interrupts being useful.
5. **More peripherals**, which by then are cheap.
6. **GUI**, a form over the YAML. *Done:* `tools/m1core_config.py`.

## The configurator

```
python3 tools/m1core_config.py [boards/gw5a25/mcu.yaml]
```

Same job as Gowin's "Gowin EMPU M1" dialog: general settings on top, then a
block diagram with the core, the AHB band, the APB band, and a band for the
expansion windows. Click a block to edit its base address, IRQ and width. The
**Add** toolbar under the diagram adds a peripheral or an expansion window.
**Save and Generate** writes `mcu.yaml` and runs the same outputs `make
checkgen` verifies.

The diagram deliberately shows only what exists. An earlier version doubled as
the palette, offering every available type as a dashed block on its bus, and a
row ran off the edge of the window — which pushed the expansion windows out of
sight, the opposite of showing them. Adding moved to the toolbar, and the
expansion windows got a band of their own rather than trailing the end of a
peripheral row.

Three properties are worth keeping:

**The palette is not a list in the GUI.** Every `tools/peripherals/<type>.yaml`
becomes a block, and which band it lands in comes from whether its `module` is
`ahb_*` or `apb_*`. Adding a peripheral type to the generator makes it appear in
the configurator with no edit to the GUI at all.

**No validation lives here.** The window calls `m1core_gen.validate()`, so the
GUI cannot produce a configuration the command line would reject, and the error
text is written once. Generate is disabled while anything fails.

**mcu.yaml is edited, not rewritten.** That file's comments are the reasoning
behind the configuration; a pyyaml load-and-dump would delete every one of them,
and ruamel is not installed. So `tools/mcu_yaml.py` substitutes scalars on their
own line and regenerates only the peripherals block, re-attaching the comment
lines above each entry by peripheral name. `make checkyaml` reads the file,
writes it back unchanged and requires the bytes to be identical, which is the
whole safety argument for editing in place.

## The standard map

`tools/standard-map.yaml` is Gowin's eMPU M1 layout, copied from their own
`GOWIN_M1.h`. Every base address and interrupt number comes from there, so a
driver written against their core works here at the same addresses and m1kern's
target layer ports over without an address change.

Two things follow from treating it as a contract rather than a default.

**The header emits all of it, whatever a build contains.** Every base address,
every register struct, and the full 32-entry interrupt map are defined even for
blocks this build does not have, so BSP and application code compiles once
against the standard layout. What is actually present is reported alongside as
`M1CORE_HAS_<name>`, because a read of an absent peripheral returns zero rather
than faulting and that is worth being able to check.

**How many of each type exist is fixed by the map.** There are two UARTs
because the map has `UART0` and `UART1`. A third has no standard base, no
standard interrupt and no name in the header contract, so `validate()` rejects
it and the configurator greys out the button. The way to add more is an APB
expansion window, where the block gets an address of its own and is understood
to be yours rather than standard.

Writing this map down caught a placement error: the RTC had been put at
`0x5000_2000`, which is Gowin's DUALTIMER. It is at `0x5000_6000`.

m1kern's `M1CORE.h` is generated from the same file with `--cmsis-header`,
using Gowin's `UART_TypeDef` / `GPIO_TypeDef` struct names so its drivers
compile unchanged. `make checkgen` covers it, so the two BSPs cannot drift.

## Peripherals

| Type | Bus | Module | Pins | Notes |
| --- | --- | --- | --- | --- |
| gpio | AHB | `ahb_gpio` | `gpio_o[width]` | data/dir with atomic set and clear |
| uart | APB | `apb_uart` | `rxd`, `txd` | CMSDK layout |
| timer | APB | `apb_timer` | none | CMSDK layout, down counter |
| rtc | APB | `apb_rtc` | none | prescaled tick counter with a match interrupt |
| spi | APB | `apb_spi` | `sclk`, `mosi`, `miso`, `ssel_n[width]` | master, all four modes, MSB first |
| i2c | APB | `apb_i2c` | `scl`, `sda` (open drain) | single master, start/byte/stop per command |

Adding one is three files and no GUI change: the RTL in `rtl/periph/`, a
`tools/peripherals/<type>.yaml`, and an entry in `sim/Makefile` plus the
`.gprj`. The configurator picks it up from the YAML.

`tb/tb_periph.sv` unit-tests SPI, I2C and RTC on their own APB ports rather
than through the CPU. Going through the core would make every register access
hundreds of cycles and would be re-testing the fabric; a shifting error inside
SPI is far easier to read at the block. SPI is tested with MISO tied to MOSI,
so a received byte equal to the transmitted one proves both directions shift on
the right edges — and that holds in all four modes, which makes it a real check
of CPOL and CPHA rather than of mode 0 only. I2C is tested against a slave
model that acks its own address, stores a byte and returns one.

Two notes on what these blocks deliberately do not do. SPI is MSB first only:
LSB first doubles every shift and sample case for a mode almost no device uses.
SPI chip selects are driven straight from a register rather than automatically
around each transfer, because a real device usually needs one select held
across several bytes and hardware that drops it every byte cannot express that.

I2C's pins are open drain, so a board carrying them needs pull-ups; nothing in
the design drives either line high. Clock stretching is honoured.

## Expansion windows

Gowin's dialog calls these "AHB master 1-6" and "APB master 1-16". They are the
windows you attach your own logic to; from the CPU's point of view the attached
block is a slave.

```yaml
  expansion:
    apb: { base: 0x60000000, slots: 16, size_kb: 1024,  enabled: 0 }
    ahb: { base: 0x80000000, slots: 6,  size_kb: 16384, enabled: 0 }
```

`slots` is how many the address map reserves. `enabled` is how many are actually
decoded by the fabric and brought out as ports on the MCU top, and it defaults
to none: six unused AHB port bundles on the top level is noise in the netlist.

**These were fiction until they were generated.** The header defined
`AHB_EXPAND_BASE 0x80000000` and the memory map documented it, but
`ahb_fabric.v` decoded only `0x0/0x2/0x4/0x5/0xe00`. An access to an expansion
window selected nothing, returned zero, and raised no error, which is
indistinguishable from hardware that works and reads back zero. Two things
changed so that cannot recur:

- the header only emits an address define for a slot that is actually enabled
- `tb/tb_exp.sv` attaches a real slave in the window and requires the data back

`tb_exp` runs against RTL generated from `tb/exp_mcu.yaml`, **not** from the
board file, so what it tests is the generator rather than the one configuration
that happens to be checked in. It also checks the top of the window decodes, an
address one past the window does not, and an unmapped read still returns zero.

Both buses work. They are generated differently, on purpose:

- **AHB** gets one fabric slave per window, each brought out as a full AHB-Lite
  slave interface. Six windows of 16 MB.
- **APB** gets *one* fabric slave for the whole 16 MB reserved window, with an
  `ahb_apb_bridge` behind it and a `psel` decoded per slot. Sixteen windows of
  1 MB. Sixteen fabric slots would grow the decode and read mux that the bridge
  exists to keep small, and the slots share the address and data phase anyway,
  which is exactly how APB works.

The full reserved APB window is decoded even when only some slots are enabled,
and an unselected slot returns `pready` high with zero data. Without that, an
access to an empty slot would wait forever on a `pready` that never arrives and
hang the bus rather than read zero. `tb_exp` covers that case explicitly, along
with slot decode, an offset within a slot, and one slot not answering for
another.

This is the shape a Cheby generated register map attaches in: one block per
slot, differing only in `psel`.

## The AHB fabric is generated

`rtl/mcu/ahb_fabric.v` is generated in full, and the fabric wiring inside
`m1core_mcu.v` is a generated region, because the fabric's port list is one
group per slave. Adding a peripheral or an expansion window changes it.

This is also what makes more than one AHB peripheral possible: AHB peripherals
are now decoded to their own size rather than to the whole `0x4` nibble. The
remaining limitation is the MCU top, where the GPIO instance is still hand
wired, so `validate()` still refuses a second AHB peripheral.

## GUI technology

Python with Qt (PySide6).

The generator is Python, so the GUI can import it directly rather than shelling
out and parsing text, and there is one language to maintain. It matches the
tooling already in use here — Cheby, the SI suite, `tools/*.py` — and Gowin's own
IDE is Qt, so it will not feel foreign next to it.

The rule that keeps it cheap: **the GUI never contains logic.** It edits YAML and
calls the generator. Every validation rule (overlapping address ranges, duplicate
IRQ numbers, a peripheral on a bus that does not exist) belongs in the generator
where the CLI gets it too, and where it can be tested without clicking anything.
A GUI that knows things the CLI does not is how these tools rot.

Steps 1 and 2 before the generator is deliberate: writing a generator against one
hypothetical peripheral produces the wrong abstraction. Two real ones is enough
to see the pattern and not so many that the rework hurts.
