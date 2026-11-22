# cortexm1_clone

An ARMv6-M compatible soft core for Gowin (Tang Primer 25K) and Xilinx Artix-7
(Basys 3) FPGAs, debuggable over SWD with a Black Magic Probe and gdb. Not an ARM product, not affiliated with ARM. "Cortex-M1"
appears here only to describe what this is binary and tool compatible with.

## Why

The Gowin Cortex-M1 works, but its CoreSight ROM table is malformed: the CIDR
preamble does not match the spec and the SCS component has no valid PIDR. Our BMP
branch in `pub/blackmagic` carries workarounds for both. This core emits a
spec-legal ROM table instead, so **stock** BMP discovers it without those hacks.

## Build order

Tier 2 (the debug access path) is being built before Tier 1 (the CPU),
deliberately. If the CPU comes first you end up debugging the CPU and the debug
interface at the same time. With the DAP done first, the core can be brought up
behind a debugger that already works.

- [x] SWD physical layer and packet framer
- [x] SW-DP, DPv1, with the power-up handshake and posted AP reads
- [x] MEM-AP with an AHB-Lite master
- [x] CoreSight ROM table and ID registers
- [x] SCS stub with CPUID 0x410CC210, enough DHCSR to report halted
- [x] GPIO peripheral, so a pin can be driven from gdb with no CPU
- [x] Blink firmware, builds for cortex-m1 and verifies over SWD in simulation
- [x] ARMv6-M core, full base instruction set, multi-cycle
- [x] Bus arbiter, debugger and core sharing the fabric
- [x] Halt / resume / single step, core registers through DCRSR/DCRDR
- [x] **On hardware: `monitor swd_scan` prints Cortex-M1**, on a Tang Primer 25K
      with stock BMP. The ID contract in `docs/id-contract.md` is validated
      against real silicon: ROM table walked, SCS PIDR 0x04000bb008, ROM partno
      0x470, designer 0x43b, CPUID recognised
- [x] **MVP milestone complete**: attach over SWD, `load`, and the core runs the
      blink firmware on a Tang Primer 25K. Debug, memory access, reset and
      execution all working on hardware
- [x] **UART working on hardware**: 115200 8N1 out of the APB bridge, verified
      with a terminal. Loop timing independently confirms the 25 MHz clock
- [x] NVIC and the exception model: SysTick, SVC, PendSV, priorities, MSP/PSP
- [x] HardFault: undefined instruction, unaligned access, bad branch target, lockup
- [x] 3-stage pipelined core, same ports and programmer's model, see
      `docs/cores.md`
- [x] m1kern (preemptive RTOS) running on both cores in simulation, and on the
      multi-cycle core on a Basys 3 (`sw/m1kern/apps/m1core_demo`)
- [ ] BPU/DWT for hardware breakpoints and watchpoints

## Layout

```
rtl/core/       m1core_cpu.v       the multi-cycle cpu, the reference core
                m1core_decode.v    instruction decode, shared by both cores
                m1core_nvic.v      nvic, systick, exception priorities
rtl/pipe/       m1core_cpu_p.v     the 3-stage pipelined cpu
                m1core_fetch.v     its fetch stage and halfword queue
                m1core_alu.v       its datapath
rtl/debug/      swd_phy, sw_dp     swd framing and the debug port
                mem_ap             turns DRW accesses into bus cycles
                ppb_regs           rom table, scs, dwt/bpu id blocks
rtl/mcu/        m1core_mcu.v       mcu top: cpu + debug + fabric + memories
                m1core_apb.v       GENERATED apb decode and peripherals
                ahb_arb            two master arbiter, debugger wins
                ahb_fabric         address decode and read mux
                ahb_sram           itcm/dtcm
rtl/periph/     gpio, uart, timer, rtc, spi, i2c

sw/baremetal/   bsp/, apps/{blink,hello}, tests/{isa,isarand,exc}
                                   no rtos, used by the testbenches
sw/m1kern/      apps/m1core_demo   our m1kern applications
                m1kern/            m1kern, git submodule
sw/gdbinit                         bmp connect, swd_scan, attach, reload

boards/gw5a25/          tang primer 25k: gprj, pins.cst, mcu.yaml, board top.v
boards/xc7a35t_basys3/  basys 3: vivado tcl, basys3.xdc, board top.v, Makefile
boards/mega60k, mega138k
tb/             testbenches, systemverilog
sim/            iverilog build
tools/          m1core_gen.py (header, apb decode, memory map from mcu.yaml),
                select_core.py, bin2hex.py, checks
docs/           cores.md, memory-map.md, mcu-config.md, id-contract.md
```

Split by role rather than by file type. `rtl/core` and `rtl/pipe` are the CPUs,
`rtl/debug` is what makes a probe recognise it, `rtl/mcu` is the assembly, and
`rtl/periph` is where the system grows.

Adding a bare metal application is three lines:

```make
APP  := myapp
SRCS := main.c
include ../../bsp/bsp.mk
```

`sw/baremetal/bsp/bsp.mk` supplies the toolchain flags, startup code, linker script and hex
conversion. An app carrying its own vector table (the ISA test does) sets
`BSP_SRCS :=` to opt out of the startup code.

## Language

RTL is plain **Verilog 2001**, not SystemVerilog. GowinSynthesis rejected the
original SystemVerilog outright, and its SV frontend is partial enough that a
miscompile is a real risk, so the design was down-converted. Details and the
check command are in `boards/gw5a25/README.md`.

Testbenches under `tb/` remain SystemVerilog; they never go near Gowin.

## Simulation

```
cd sim && make            # everything, both cores
make dap                  # phy + dp only
make core                 # isa test on the multi-cycle cpu
make blink                # cpu runs blink, pin toggles
make mvp                  # full debug path
make exc                  # exception model
make pipeline             # the suites above on the pipelined core, plus excp
make m1kern m1kernp       # m1kern 01_blink on each core (opt in, slow)
vvp build/tb_dap +dbg     # trace decoded swd requests
vvp build/tb_core +trace  # instruction trace
make wave                 # vcd + gtkwave
```

The MVP test walks the same discovery path
`adi.c` does, in the same order: DPIDR, power up, AP IDR and BASE, ROM table
CIDR/PIDR/MEMTYPE, entry decode to the SCS, SCS CIDR/PIDR, CPUID, the DHCSR halt
handshake, core registers through DCRSR/DCRDR, then ITCM/DTCM writes, TAR
auto-increment streaming, and sub-word writes.

## Memory map

See `docs/memory-map.md`, generated from `boards/gw5a25/mcu.yaml`. The short
version: ITCM at 0x00000000 (gdb `load` lands here), DTCM at 0x20000000, GPIO0
at 0x40000000, the APB peripherals from 0x50000000, the PPB at 0xE0000000.

## The core

There are two: a multi-cycle reference core (`rtl/core/m1core_cpu.v`) and a
3-stage pipeline (`rtl/pipe/m1core_cpu_p.v`), with the same ports and the same
programmer's model. `docs/cores.md` compares them, with diagrams, numbers, how
to pick one per board, and what an RTOS needs from either. The rest of this
section describes the multi-cycle core.

Instruction fetch is one halfword at a time. That costs cycles but removes every
alignment special case, because a 32-bit Thumb instruction is simply two
halfword fetches.

Implemented: the full ARMv6-M base instruction set. Shifts, add/sub in every
form, all the data-processing register ops, the special-data and BX/BLX group,
loads and stores at all widths with sign extension, LDR literal, ADR, ADD/SUB
SP, sign and zero extends, byte reverses, PUSH/POP, STMIA/LDMIA, conditional and
unconditional branches, BL, CPS, and the hints.

Exceptions and the NVIC are implemented: banked MSP/PSP, CONTROL.SPSEL, IPSR,
stacking and unstacking of the 8-word frame, EXC_RETURN via both `bx lr` and
`pop {pc}`, SVC taken synchronously, PendSV and SysTick through the NVIC, and
priority-ordered preemption with PRIMASK masking. MSR/MRS reach MSP, PSP,
PRIMASK, CONTROL and IPSR, which is what an RTOS context switch needs.

HardFault is implemented, with three sources: an undefined instruction, an
unaligned data access, and a branch to an address with the Thumb bit clear.
A fault taken while already at HardFault priority has nowhere to escalate to, so
the core locks up and reports `S_LOCKUP` in DHCSR, which is what real hardware
does. BKPT still halts, which surfaces in gdb rather than misbehaving silently.

All three used to be silent, and the third is the one most likely to bite: a bad
function pointer had its Thumb bit masked away and execution carried on
wherever it landed.

Execution starts the way every Cortex-M does: on reset the core reads word 0 of
the vector table into MSP and word 1 into PC. Bit 0 of the reset vector must be
1, the Thumb bit, because ARMv6-M has no ARM state.

There are two bus masters now, the MEM-AP and the core, so `ahb_arb` arbitrates
with the debugger at fixed higher priority. A debugger access is rare, must
never be starved, and the core is usually halted anyway when one happens.

## Verification

`tb_core` runs `fw/isatest.S`, a self-checking assembly test, on the core with no
debugger involved. It reports through DTCM: error count, first failing test id,
and a completion marker. 50 checks, all passing.

Two core bugs it caught are worth recording, because both were silent:

- Three `casez` patterns in the misc-16-bit block matched only `inst[7]==0`, so
  UXTH, UXTB, SUB SP and REVSH all fell through to the PUSH/POP default and did
  nothing at all.
- ADD/SUB SP scales its 7-bit immediate by 4; it was scaled by 2. The original
  test passed anyway because it only checked a value loaded and stored through
  SP, and both directions were equally wrong. It took a test that compares SP
  against itself across a sub/add pair to expose it.

The lesson generalised: check the architectural state the instruction actually
modifies, not just a value that round-trips through it.

Three more, all in the debug control path and all found by extending the
testbench after hardware showed the symptom:

- **No reset path.** With no nRST wired, `AIRCR.SYSRESETREQ` is the *only* way a
  debugger can reset the core, and it did nothing. So `gdb load` wrote new
  firmware while the core stayed halted at a stale PC with a stale SP, and
  resuming ran from the middle of the old image. Pressing the board's reset
  button worked because that re-ran the vector fetch, which is exactly what
  SYSRESETREQ now does.
- **Nothing latched the halt.** `ST_HALTED` only stayed put while `C_HALT` was
  asserted, so a halt caused by anything else (vector catch, BKPT, a completed
  step) lasted one cycle and the core ran away. Real hardware sets `C_HALT` on a
  debug event; the core now raises a halt event and the SCS latches it.
- **A one-cycle race on top of that.** Even with the latch, the core sampled
  `C_HALT` in the same cycle it halted, before the SCS could set it, and executed
  exactly one instruction past the halt point. The resume is now gated by one
  cycle. The tell was a PC of 0x46 and an SP 8 bytes low: one `push {r4, lr}`.

A fourth bug only hardware could have found: the MEM-AP ignored `SELECT.APSEL`
because the signal was decoded by the DP and then left dangling. A probe walks
APSEL 0..255 and decides an AP is absent when its IDR reads 0, so a single AP
answering at every APSEL got enumerated as 256 identical Cortex-M1 targets, until
BMP ran out of heap. Simulation never caught it because the testbench only ever
used APSEL 0. There are now checks at APSEL 1 and 255.

## Firmware

```
cd sw && make
```

Builds with `arm-none-eabi-gcc -mcpu=cortex-m1 -mthumb`, links code at ITCM and
data at DTCM with `.data` stored in ITCM and copied by the reset handler, and
emits `blink.elf`, `.bin`, and a word-per-line `.hex` for the testbench. 188
bytes, all 16-bit Thumb apart from one `bl`, which is one of the few 32-bit
encodings ARMv6-M includes.

The MVP testbench loads that real image over SWD and verifies every word back,
which is what `gdb compare-sections` does.

## Bring-up session in gdb

```
(gdb) target extended-remote /dev/ttyBmpGdb
(gdb) monitor swd_scan
(gdb) attach 1
(gdb) set *(unsigned*)0x40000004 = 3      # dir, both pins output
(gdb) set *(unsigned*)0x40000008 = 1      # set bit 0, led on
(gdb) set *(unsigned*)0x4000000c = 1      # clear bit 0, led off
(gdb) load fw/build/blink.elf
(gdb) x/8x 0
(gdb) continue
```

If the LED changes state from those pokes, the debug chain works: SWD framing,
DP, MEM-AP, AHB fabric, peripheral. If it then blinks on its own after
`continue`, the core works too.

## Hardware bring-up, in order

See `boards/gw5a25/README.md` for the Tang Primer 25K. On the Basys 3,
`make prog` in `boards/xc7a35t_basys3` builds and loads the bitstream, with SWD
on Pmod JA (pin 1 SWCLK, pin 2 SWDIO) and UART0 on the board's USB serial port.

1. Build and load the bitstream.
2. Watch the bring-up staircase on the first four LEDs (`m1core_mcu.v`): LED0
   heartbeat, LED1 SWCLK edges arriving, LED2 a line reset recognised (latched),
   LED3 a packet decoded (latched). The highest one lit says how far the probe
   got. LED2 without LED3 usually means SWDIO is not connected.
3. `monitor swd_scan` should print a Cortex-M1. If the ROM table is right this
   works on **stock** BMP, no patch needed.
4. `attach 1`, then `load` an ELF linked at 0x00000000. Verify with
   `x/8x 0x0`.

Expect gdb to use software breakpoints: NUM_CODE in the BPU reads 0 because
there are no comparators yet. That is fine with code in RAM.

## Known scaffolding

`ppb_regs` holds a 32-entry core register file so DCRSR/DCRDR return something
to gdb. That is about 1000 flip-flops and it exists only until the real CPU
register file lands, at which point DCRSR routes there instead.

## Notes for hardware bring-up

`clk` must be at least 4x SWCLK. SWCLK is oversampled rather than treated as a
clock domain, so it does not consume a Gowin global clock resource. At 27 MHz
system clock a probe running at a few MHz has ample margin; slow the probe with
`monitor frequency` if needed.

Two framing rules that are easy to get wrong and are both covered by the
testbench:

- A line reset is a run of 50+ ones, every one of which looks like a start bit.
  Start detection has to stay disarmed until a zero is seen.
- The turnaround clock at the end of a transaction is undriven and floats high
  through the pull-up. It must be consumed as part of the transaction or it gets
  mistaken for the next packet's start bit.
