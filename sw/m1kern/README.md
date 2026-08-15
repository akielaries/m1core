# m1kern on m1core

Applications that want threads, preemption and a scheduler use
[m1kern](../../../m1kern), which has an `m1core` target. This directory is the
integration point, not a copy of the kernel.

## Build and run

```
make            # builds 01_blink for m1core at 25 MHz
make ARGS="--target 03_priority.elf"
```

then from gdb:

```
(gdb) load build/bin/01_blink.elf
(gdb) run
```

LED0 toggles every 250 ms and LED1 every 500 ms, so on a scope you should see
2 Hz and 1 Hz. Both being correct means SysTick is running at a true 1000 Hz,
not merely running.

## What m1kern needs from the SoC

| Requirement | Where |
| --- | --- |
| SysTick, SVC, PendSV, NVIC priorities | architectural, in `rtl/core/m1core_nvic.v` |
| 32K ITCM, 16K DTCM | `boards/gw5a25/top.v`, must match m1kern's linker script |
| UART0 at 0x50004000 | `rtl/periph/apb_uart.v` |
| `SystemCoreClock` | compile time, must match the synthesised clock |

`SYSTEM_CLOCK_HZ` is a constant because there is no PLL to read back. It is 25
MHz on the Tang Primer 25K, because `top.v` divides the 50 MHz oscillator by
two.

## Why this is separate from `../baremetal`

`sw/baremetal/tests` must never depend on m1kern. Those tests exist to prove the
CPU works, so requiring a kernel would mean a core bug and a kernel bug look
identical, and the hardware could not be tested without a second repository.
That independence is what makes failures diagnosable: when m1kern hung during
bring-up, `tb_core` still passing proved the ISA was fine and pointed straight
at the exception path.

`sw/baremetal/apps` are the minimal no-RTOS demonstrations, and are what
`tb_blink` and `tb_hello` run. Anything beyond that belongs here.
