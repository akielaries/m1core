# SoC configuration and generation

How m1core gets configured: which peripherals exist, where they live, and which
interrupt each one owns. This is the scaffolding that makes peripherals cheap to
add and makes a configurator GUI a thin layer rather than a rewrite.

## The core argument: generate, don't parameterise

There are two ways to make a SoC configurable.

**Parameterise.** One `m1core_soc.v` with `HAS_UART`, `HAS_SPI`, `NUM_GPIO`
parameters and `generate` blocks around every instance. This is where these
projects usually end up, and it rots: the fabric decode becomes a nest of
conditionals, the address map is implicit in the RTL, adding a peripheral edits
five files, and the C header drifts from the hardware.

**Generate.** Describe the SoC as data, and emit the RTL. Gowin's own IP
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
| Composition *of* the SoC | is there a UART0, at what base, on which IRQ | m1core generator |

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

One file describes an SoC instance:

```yaml
soc:
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

- `m1core_soc_gen.v` — the APB decoder, peripheral instances, IRQ vector
- `m1core_soc.h` — base addresses, IRQ enum, matching the CMSIS layout m1kern
  expects
- `memory-map.md` — the same information for humans

Peripheral register definitions stay in Cheby YAML per block, so the generator
never needs to know what is inside a UART.

## Order of work

1. **AHB-to-APB bridge**, and a written peripheral contract. Structural, and
   everything else assumes it.
2. **UART on APB.** The first real peripheral, and the thing that proves the
   contract end to end. Also the most immediately useful: printf beats an LED.
3. **Generator**, once there are two peripherals to compose and the shape of the
   problem is known from real examples rather than guessed at.
4. **Exceptions and NVIC.** The gate to m1kern and to interrupts being useful.
5. **More peripherals**, which by then are cheap.
6. **GUI**, a form over the YAML.

Steps 1 and 2 before the generator is deliberate: writing a generator against one
hypothetical peripheral produces the wrong abstraction. Two real ones is enough
to see the pattern and not so many that the rework hurts.
