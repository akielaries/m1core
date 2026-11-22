# m1core

An ARMv6-M (Cortex-M1 compatible) soft core with a CoreSight-legal SWD debug
port, so a stock Black Magic Probe and gdb attach, load and debug it. Runs on a
Tang Primer 25K and a Digilent Basys 3, and runs the m1kern RTOS.

## repositories

- [m1core](https://github.com/akielaries/m1core): RTL, testbenches, board builds, firmware, these docs
- [m1kern](https://github.com/akielaries/m1kern): the preemptive RTOS, a submodule at `sw/m1kern/m1kern`
- [signalmesh](https://akielaries.github.io/signalmesh/): the synth project the Basys 3 build is shared with

## docs

- [details](details.md): what is built, layout, simulation, verification, bring-up
- [the two cores](cores.md): multi-cycle and pipelined compared, diagrams, what an RTOS needs, the PSP push/pop bug
- [memory map](memory-map.md): generated from `boards/gw5a25/mcu.yaml`
- [mcu configuration](mcu-config.md): describing an SoC in `mcu.yaml` and generating from it
- [CoreSight ID contract](id-contract.md): the ROM table and IDs a probe expects, derived from the BMP source
- [SoC diagram](https://viewer.diagrams.net/?nav=1#Uhttps%3A%2F%2Fraw.githubusercontent.com%2Fakielaries%2Fm1core%2Fmain%2Fdocs%2Fdiagrams%2Fm1core-soc.drawio): draw.io, cpu, debug path, fabric, memories, peripherals

## quick start

```
cd sim && make                                 # regression, both cores
cd boards/xc7a35t_basys3 && make prog          # basys 3 bitstream over usb
cd sw/m1kern && make BOARD=basys3              # m1core_demo
```

Then in gdb with a Black Magic Probe on Pmod JA: `mon swd`, `attach 1`,
`file sw/m1kern/build/basys3/bin/m1core_demo.elf`, `reload`.
