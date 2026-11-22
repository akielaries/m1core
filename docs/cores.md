# The two cores

m1core has two CPU implementations of the same ARMv6-M programmer's model. They
have the same port list, so `rtl/mcu/m1core_mcu.v` takes either one, and
firmware, gdb and the debug path cannot tell them apart except by speed.

| | Multi-cycle | Pipelined |
| --- | --- | --- |
| Source | `rtl/core/m1core_cpu.v` | `rtl/pipe/m1core_cpu_p.v`, `m1core_fetch.v`, `m1core_alu.v` |
| Structure | one state machine, one instruction at a time | 3 stages: fetch, decode, execute |
| Fetch | one halfword per bus access, through the AHB fabric | one 32-bit word per cycle into a halfword queue, on a dedicated ITCM port |
| Data to TCM | through the arbiter and fabric | dedicated DTCM port, no wait states |
| CPI, `tb_core` ISA test | 5.51 | 3.09 |
| m1kern throughput, `m1core_demo` spinners | 1x | 1.94x on the Basys 3 at 50 MHz (1.35M vs 0.70M loops/s per spinner), 3.8x in sim at a 4 MHz tick rate |
| Exceptions, NVIC, MSP/PSP | yes | yes |
| Halt, step, DCRSR/DCRDR, vector catch | yes | yes |
| Basys 3 at 50 MHz, whole SoC | 5436 LUT, 2589 FF, 12 BRAM tiles, WNS +0.35 ns | 5286 LUT, 3225 FF, 20 BRAM tiles, WNS +1.87 ns |
| Core alone (`u_core`) | 3719 LUT, 1377 FF | 3649 LUT, 2012 FF |
| Simulation | `make core blink hello mvp exc m1kern` | `make pipeline` (includes `excp`), `make m1kernp` |

The pipelined core is the faster one and, despite having more registers, is no
bigger in LUTs and has more timing slack. The extra BRAM is the dedicated TCM
ports: each TCM becomes true dual port, the core on one side and the debugger's
AHB path on the other.

## Choosing one

- **Gowin builds:** `tools/select_core.py pipeline|multicycle`. It rewrites the
  guard at the top of `m1core_mcu.v` and the `.gprj` file list together, because
  Gowin picks as top whatever module nothing instantiates, so both cores in the
  project breaks the build.
- **Basys 3:** `make CORE=pipeline` (default) or `make CORE=multicycle` in
  `boards/xc7a35t_basys3`. Each core builds into its own `build/<core>/` with
  its own Vivado project, so switching needs no clean. `rtl.tcl` picks the files
  and the define.
- **Simulation:** pinned on the iverilog command line with
  `-DM1CORE_FORCE_MULTICYCLE` or `-DM1CORE_PIPELINE`, so a test always exercises
  the core it names whatever the bitstream is set to.

The multi-cycle core is the reference: simpler, and every pipeline test is
checked against what it does. The Basys 3 defaults to the pipelined core, which
since the stack pointer fix below runs m1kern on the board about 1.9x faster.

## Multi-cycle

```
            +-------------------------------------------------+
            |                  state machine                  |
            |                                                 |
 reset ---> | RST_SP -> RST_PC -> FETCH -> (FETCH2) -> EXEC   |
            |                       ^                  |      |
            |                       |   MEM_A/MEM_D <--+      |
            |                       |   MULTI_A/D   <--+ ldm  |
            |                       |   EXC_PUSH/VEC <-+ exc  |
            |                       +------------------+      |
            +----------------------------+--------------------+
                                         |
                                  one AHB master
                                         |
                        ahb_arb (debugger wins) -> ahb_fabric -> ITCM, DTCM, APB, PPB
```

Every instruction walks the states it needs and nothing overlaps. A 16-bit
instruction is FETCH_A, FETCH_D, EXEC, plus MEM_A/MEM_D for a load or store; a
32-bit one (BL, MSR, MRS, the barriers) adds FETCH2. In the `tb_core` run 41%
of cycles are fetch, which is the cost of fetching a halfword at a time through
the shared bus. The upside is that there is no alignment case anywhere and no
hazard to reason about: when EXEC runs, everything before it has finished.

## Pipelined

```
        F                       D                          E
 +--------------+      +------------------+      +-----------------------+
 | m1core_fetch |      | decode table     |      | shared datapath (alu, |
 | 32-bit itcm  | ---> | register read    | ---> | shifter, multiplier)  |
 | access/cycle |      | operand select   |      | branch resolve        |
 | halfword     |      | forwarding from  |      | memory address, data  |
 | queue        |      | E and W          |      | phases                |
 +--------------+      +------------------+      +-----------+-----------+
        ^                                                    |
        |            redirect (branch, exception, msr)       |  W: register
        +----------------------------------------------------+  file write a
                                                                 cycle later
 sequencer states outside ST_RUN: reset vector fetch, LDM/STM/PUSH/POP
 (ST_SEQ_*), exception push/vector/pop, halted
```

- **Fetch** reads a 32-bit word per cycle from the ITCM port into a halfword
  queue, so 16-bit and 32-bit Thumb instructions come out of the same queue.
- **Decode** reads the register file and forwards from E and W.
- **Execute** has one datapath. A memory instruction stays in E for two cycles,
  address phase then data phase, and the pipeline holds behind it. That is why
  there is no separate load-use interlock: the dependent instruction waits in D
  for both phases, and forwarding the load data covers the one cycle where the
  register file write has not landed yet.
- **Branches** resolve in E and redirect fetch. MSR to a stack pointer or
  CONTROL also redirects, so the next instruction sees the new SP bank.
- **Multi-register transfers and exceptions** leave the pipeline for a small
  sequencer (`ST_SEQ_*`, `ST_EXC_*`) and come back to `ST_RUN` when done.

The stack pointer is banked (`sp_main`, `sp_process`) and never stored in the
register file. Which bank a read uses is a register, `use_psp`, updated a cycle
after mode or CONTROL changes. Everything that changes it also redirects, so the
stale cycle never reaches an instruction.

## What an RTOS needs from either core

m1kern exercises exactly the parts of the exception model that simple firmware
never touches. Its first switch, and every later one:

```
 thread (main)        kernel_start: PSP = thread0 frame, CONTROL.SPSEL = 1, svc #0
      |
      v
 SVC_Handler          pend PendSV, return
      |
      v
 PendSV_Handler       on MSP. save r4-r11 below the hw frame on the old PSP,
      |               current->sp = that. scheduler_next(). PSP = next->sp,
      |               restore r8-r11 and r4-r7, return with EXC_RETURN 0xFFFFFFFD
      v
 next thread          on PSP, thread mode. the core unstacks r0-r3, r12, lr, pc,
                      xpsr from PSP
      ^
      |  SysTick_Handler: system_time_ms++, pend PendSV, every 1 ms
```

That needs, from the core:

| Feature | Used for |
| --- | --- |
| Banked MSP/PSP, CONTROL.SPSEL | handlers on MSP, threads on PSP |
| 8-word hardware frame, stacked on the active SP | PendSV saves only r4-r11 by hand |
| EXC_RETURN via `pop {pc}` and `bx lr` | PendSV returns with `pop {r4, pc}` |
| SVC, PendSV, SysTick, priorities | first switch, preemption, tick |
| MSR/MRS of PSP, CONTROL, PRIMASK | context switch, `cpsid`/`cpsie` |
| PUSH/POP and LDM/STM on PSP in thread mode | every function call in a thread |

The last row is the one that was broken.

## Bug: PUSH/POP on PSP wrote MSP (pipelined, fixed)

On the pipelined core, the LDM/STM sequencer's stack pointer writeback
(`ST_SEQ_D` in the `spw_*` mux) was hardwired to the MSP bank. In handler mode,
or in thread mode on MSP, that is correct, which is everything `tb_exc` and the
bare metal apps do. In thread mode on PSP, a `push` computed `PSP - 8` correctly
and then wrote it to MSP, leaving PSP unchanged. The next `pop` read its return
address from the wrong place.

Under m1kern that fails on the first nested call inside the first thread:
`blink_slow_fn -> led_toggle -> GPIO_Toggle`, and GPIO_Toggle's `pop {r7, pc}`
returns to address 0. The core then runs the vector table as code, reaches the
thread entry again, and loops until a HardFault. On hardware that looks like a
banner followed by silence, and the BMP losing the target.

The fix selects the bank like every other writer does: `spw_psp = use_psp`.
`make m1kernp` runs m1kern's `01_blink` on the pipelined core and is the
regression for it.

Found by tracing `e_pc`, `sp_main` and `sp_process` in `tb_m1kern` built with
`-DM1CORE_PIPELINE`: after the first `push` in the thread, MSP had moved and PSP
had not.

The debug write path in `ST_HALTED` has the same shape: a gdb write to SP
(DCRSR REGSEL 13) always goes to MSP, and REGSEL 18 (PSP) is not routed. That
only matters when gdb writes SP while a thread on PSP is halted.
