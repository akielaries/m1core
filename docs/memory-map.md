# m1core memory map

Deliberately the same map as Gowin's eMPU M1, and the peripherals are
register-compatible with ARM's CMSDK blocks, which is what Gowin used. Same
reasoning as the CoreSight ID contract: matching an existing convention costs
nothing and means existing software works unchanged. `GOWIN_M1_uart.c` from
m1kern's BSP drives our UART as-is.

## Regions

| Base | Region | Bus | Notes |
| --- | --- | --- | --- |
| 0x0000_0000 | ITCM | AHB | code, zero wait state |
| 0x2000_0000 | DTCM | AHB | data, zero wait state |
| 0x4000_0000 | AHB1 peripherals | AHB | fast peripherals |
| 0x5000_0000 | APB1 peripherals | APB | behind the bridge |
| 0x6000_0000 | APB expansion | APB | 16 slots, 1 MB each |
| 0x8000_0000 | AHB expansion | AHB | 6 slots, 16 MB each |
| 0xE000_0000 | PPB | AHB | SCS, ROM table, debug |

## AHB1 peripherals, 0x4000_0000

| Address | Block | State |
| --- | --- | --- |
| 0x4000_0000 | GPIO0 | implemented |
| 0x4500_0000 | CAN | not planned |
| 0x4600_0000 | Ethernet | not planned |

## APB1 peripherals, 0x5000_0000

Offsets follow Gowin/CMSDK so the BSP headers line up.

| Address | Block | IRQ | State |
| --- | --- | --- | --- |
| 0x5000_0000 | TIMER0 | 2 | planned |
| 0x5000_1000 | TIMER1 | 3 | planned |
| 0x5000_2000 | DUALTIMER | 11 | planned |
| 0x5000_4000 | UART0 | 0 | **implemented**, cmsdk compatible |
| 0x5000_5000 | UART1 | 1 | planned |
| 0x5000_6000 | RTC | 6 | planned |
| 0x5000_8000 | WDOG | - | planned |
| 0x5000_A000 | I2C | 7 | planned |
| 0x5000_B000 | SPI | - | planned |
| 0x5000_F000 | TRNG | 12 | planned |

## Expansion slots

These are the useful part of Gowin's "AHB master 1-6" and "APB master 1-16"
options: address windows reserved for blocks that are not part of m1core, so you
can drop your own in without touching the map.

| Slot | Base | Size |
| --- | --- | --- |
| APB expansion 1..16 | 0x6000_0000 + n*0x0010_0000 | 1 MB |
| AHB expansion 1..6 | 0x8000_0000 + n*0x0100_0000 | 16 MB |

Naming them "master" is Gowin's; they are slaves from the CPU's point of view.

## Interrupts

Numbering follows Gowin's eMPU M1 so m1kern's target layer ports unchanged.

| IRQ | Source |
| --- | --- |
| 0 | UART0 |
| 1 | UART1 |
| 2 | TIMER0 |
| 3 | TIMER1 |
| 4 | GPIO0 |
| 5 | UART0/1 overflow |
| 6 | RTC |
| 7 | I2C |
| 11 | DualTimer |
| 12 | TRNG |

Unused lines tie low. Nothing is wired yet: the NVIC does not exist, so UART0
currently drives an interrupt output that goes nowhere.

## Not matching Gowin

One deliberate difference. Gowin's GPIO follows the CMSDK layout
(DATA/DATAOUT/OUTENSET/OUTENCLR); ours is currently DATA/DIR/SET/CLR, which
predates this decision. Realigning it would break the blink demo that is
presently working on hardware, so it is a separate deliberate change rather than
something to slip in alongside the UART.
