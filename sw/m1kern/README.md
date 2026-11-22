# m1kern on m1core

Applications that want threads, preemption and a scheduler use
[m1kern](https://github.com/akielaries/m1kern), which has an `m1core` target.
It is a git submodule at `m1kern/`, so the kernel is in `m1kern/kernel/`, the
m1core port in `m1kern/targets/m1core/` and the example sources in
`m1kern/examples/<name>/main.c`. This directory only adds the wrapper Makefile.

After cloning:

```
git submodule update --init
```

## Build and run

```
make list                                  # available examples
make                                       # 01_blink for the 25k at 25 MHz
make BOARD=basys3 TARGET=05_preemption     # basys 3 at 50 MHz
```

Output goes to `build/<board>/bin/<example>.elf`. Then from gdb:

```
(gdb) file build/basys3/bin/05_preemption.elf
(gdb) reload
```

LED0 toggles every 250 ms and LED1 every 500 ms, so on a scope you should see
2 Hz and 1 Hz. Both being correct means SysTick is running at a true 1000 Hz,
not merely running.

## What m1kern needs from the MCU

| Requirement | Where |
| --- | --- |
| SysTick, SVC, PendSV, NVIC priorities | architectural, in `rtl/core/m1core_nvic.v` |
| 32K ITCM, 16K DTCM | `boards/gw5a25/top.v`, must match m1kern's linker script |
| UART0 at 0x50004000 | `rtl/periph/apb_uart.v` |
| `SystemCoreClock` | compile time, must match the synthesised clock |

`SYSTEM_CLOCK_HZ` is a constant because there is no PLL to read back. `BOARD`
picks it: 25 MHz on the Tang Primer 25K (`top.v` divides the 50 MHz oscillator
by two) and 50 MHz on the Basys 3 (MMCM from 100 MHz).

## Why this is separate from `../baremetal`

`sw/baremetal/tests` must never depend on m1kern. Those tests exist to prove the
CPU works, so requiring a kernel would mean a core bug and a kernel bug look
identical, and the hardware could not be tested without a second repository.
That independence is what makes failures diagnosable: when m1kern hung during
bring-up, `tb_core` still passing proved the ISA was fine and pointed straight
at the exception path.

`sw/baremetal/apps` are the minimal no-RTOS demonstrations, and are what
`tb_blink` and `tb_hello` run. Anything beyond that belongs here.
