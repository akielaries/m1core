# cortexm1_clone

An ARMv6-M (Cortex-M1 compatible) soft core with a CoreSight-legal SWD debug
port, so stock Black Magic Probe and gdb attach, load and debug it. Runs on a
Tang Primer 25K and a Digilent Basys 3, and runs the m1kern RTOS.

- `DETAILS.md`: what is built, layout, simulation, bring-up
- `docs/cores.md`: the multi-cycle and pipelined cores compared
- `docs/memory-map.md`, `docs/mcu-config.md`, `docs/id-contract.md`
- `sw/m1kern/`: m1kern applications, `boards/`: per-board builds
