/*
 * m1core device header
 *
 * GENERATED from boards/gw5a25/mcu.yaml by tools/m1core_gen.py. Do not edit.
 * Change the SoC description and regenerate, so the RTL, this header and
 * docs/memory-map.md cannot drift apart.
 *
 * Register layouts come from tools/peripherals/<type>.yaml.
 */
#ifndef M1CORE_H
#define M1CORE_H

#include <stdint.h>

/* the fabric clock. software cannot read this back, there is no PLL to
   interrogate: 50 MHz oscillator divided by two in top.v */
#define SYSTEM_CLOCK_HZ  25000000u

/* address regions */
#define ITCM_BASE        0x00000000u
#define DTCM_BASE        0x20000000u
#define AHB1PERIPH_BASE  0x40000000u
#define APB1PERIPH_BASE  0x50000000u
/* peripheral instances */
#define GPIO0_BASE       0x40000000u
#define TIMER0_BASE      0x50000000u
#define UART0_BASE       0x50004000u

/* interrupt numbers. numbering follows gowin's empu m1 so m1kern's
   target layer ports across unchanged */
typedef enum {
  UART0_IRQn   = 0,
  TIMER0_IRQn  = 2,
  GPIO0_IRQn   = 4
} IRQn_Type;

/* simple gpio, data/dir with atomic set and clear */
typedef struct {
  volatile uint32_t DATA;  /* 0x00 current output value */
  volatile uint32_t DIR;   /* 0x04 1 = drive the pin */
  volatile uint32_t SET;   /* 0x08 write ones to set */
  volatile uint32_t CLR;   /* 0x0c write ones to clear */
} gpio_t;

/* cmsdk compatible down counting timer */
typedef struct {
  volatile uint32_t CTRL;       /* 0x00 [0]EN [1]SELEXTEN [2]SELEXTCLK [3]IRQEN */
  volatile uint32_t VALUE;      /* 0x04 current value, counts down */
  volatile uint32_t RELOAD;     /* 0x08 loaded when the counter wraps */
  volatile uint32_t INTSTATUS;  /* 0x0c read pending, write one to clear */
} timer_t;

/* cmsdk compatible uart, so GOWIN_M1_uart.c drives it unchanged */
typedef struct {
  volatile uint32_t DATA;       /* 0x00 tx on write, rx on read */
  volatile uint32_t STATE;      /* 0x04 [0]TXBF [1]RXBF [2]TXOR [3]RXOR */
  volatile uint32_t CTRL;       /* 0x08 [0]TXEN [1]RXEN [2]TXIRQEN [3]RXIRQEN */
  volatile uint32_t INTSTATUS;  /* 0x0c read pending, write 1 to clear */
  volatile uint32_t BAUDDIV;    /* 0x10 system clocks per bit, min 16 */
} uart_t;

/* instance pointers */
#define GPIO0  ((gpio_t *)GPIO0_BASE)
#define TIMER0 ((timer_t *)TIMER0_BASE)
#define UART0  ((uart_t *)UART0_BASE)

/* register bits */
#define TIMER_CTRL_EN            (1u << 0)
#define TIMER_CTRL_SELEXTEN      (1u << 1)
#define TIMER_CTRL_SELEXTCLK     (1u << 2)
#define TIMER_CTRL_IRQEN         (1u << 3)
#define UART_STATE_TXBF          (1u << 0)
#define UART_STATE_RXBF          (1u << 1)
#define UART_STATE_TXOR          (1u << 2)
#define UART_STATE_RXOR          (1u << 3)
#define UART_CTRL_TXEN           (1u << 0)
#define UART_CTRL_RXEN           (1u << 1)
#define UART_CTRL_TXIRQEN        (1u << 2)
#define UART_CTRL_RXIRQEN        (1u << 3)

#endif /* M1CORE_H */
