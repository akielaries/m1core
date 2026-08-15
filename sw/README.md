# Software

Two flavours, deliberately separate.

| Directory | What |
| --- | --- |
| `baremetal/` | no runtime beyond a startup file. bring-up proof and the RTL testbench firmware |
| `m1kern/` | threads and preemption, via the m1kern RTOS |

`baremetal/bsp/m1core.h` is the device header: register map, peripheral structs
and IRQ numbers, the same role `stm32f4xx.h` plays for a vendor part.

`baremetal/tests` must stay dependency free. They exist to prove the CPU works,
so a kernel in the way would make a core bug and a kernel bug indistinguishable.
