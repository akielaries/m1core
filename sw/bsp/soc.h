#ifndef SOC_H
#define SOC_H

#include <stdint.h>

/*
 * m1core memory map. deliberately the same as gowin's empu m1, and the
 * peripherals are register compatible with arm's cmsdk blocks, which is what
 * gowin used. see docs/memory-map.md
 */
#define ITCM_BASE        0x00000000u
#define DTCM_BASE        0x20000000u
#define AHB1PERIPH_BASE  0x40000000u
#define APB1PERIPH_BASE  0x50000000u
#define APB_EXPAND_BASE  0x60000000u
#define AHB_EXPAND_BASE  0x80000000u

#define GPIO0_BASE       (AHB1PERIPH_BASE + 0x0000000u)
#define TIMER0_BASE      (APB1PERIPH_BASE + 0x0000u)
#define TIMER1_BASE      (APB1PERIPH_BASE + 0x1000u)
#define UART0_BASE       (APB1PERIPH_BASE + 0x4000u)
#define UART1_BASE       (APB1PERIPH_BASE + 0x5000u)

/* interrupt numbers, matching gowin's empu m1 so m1kern ports cheaply */
typedef enum {
  UART0_IRQn  = 0,
  UART1_IRQn  = 1,
  TIMER0_IRQn = 2,
  TIMER1_IRQn = 3,
  GPIO0_IRQn  = 4,
  RTC_IRQn    = 6,
  I2C_IRQn    = 7
} IRQn_Type;

/* gpio. note: not yet cmsdk compatible, see docs/memory-map.md */
typedef struct {
  volatile uint32_t DATA;
  volatile uint32_t DIR;
  volatile uint32_t SET;
  volatile uint32_t CLR;
} gpio_t;

/* cmsdk uart */
typedef struct {
  volatile uint32_t DATA;       /* 0x00 tx on write, rx on read      */
  volatile uint32_t STATE;      /* 0x04 [0]TXBF [1]RXBF [2]TXOR [3]RXOR */
  volatile uint32_t CTRL;       /* 0x08 [0]TXEN [1]RXEN [2]TXIRQEN [3]RXIRQEN */
  volatile uint32_t INTSTATUS;  /* 0x0c read pending, write 1 to clear */
  volatile uint32_t BAUDDIV;    /* 0x10 system clocks per bit, min 16  */
} uart_t;

#define GPIO  ((gpio_t *)GPIO0_BASE)
#define UART0 ((uart_t *)UART0_BASE)

#define UART_STATE_TXBF  (1u << 0)
#define UART_STATE_RXBF  (1u << 1)
#define UART_CTRL_TXEN   (1u << 0)
#define UART_CTRL_RXEN   (1u << 1)

/* the tang primer 25k board divides its 50 mhz oscillator by two */
#define SYSTEM_CLOCK_HZ  25000000u

void uart_init(uint32_t baud);
void uart_putc(char c);
void uart_puts(const char *s);
void uart_puthex(uint32_t v);

#endif
