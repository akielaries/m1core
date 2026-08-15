#include "m1core.h"
#include "uart.h"

/* BAUDDIV is system clocks per bit. the cmsdk block requires at least 16 */
void uart_init(uint32_t baud)
{
#ifdef SIM_FAST_BAUD
  /* the testbenches cannot afford thousands of clocks per bit */
  uint32_t div = 16u;
  (void)baud;
#else
  uint32_t div = SYSTEM_CLOCK_HZ / baud;

  if (div < 16u) {
    div = 16u;
  }
#endif

  UART0->BAUDDIV = div;
  UART0->CTRL = UART_CTRL_TXEN | UART_CTRL_RXEN;
}

void uart_putc(char c)
{
  while (UART0->STATE & UART_STATE_TXBF) {
  }

  UART0->DATA = (uint32_t)(unsigned char)c;
}

void uart_puts(const char *s)
{
  while (*s) {
    if (*s == '\n') {
      uart_putc('\r');
    }
    uart_putc(*s++);
  }
}

void uart_puthex(uint32_t v)
{
  static const char digits[] = "0123456789abcdef";
  int i;

  uart_putc('0');
  uart_putc('x');

  for (i = 28; i >= 0; i -= 4) {
    uart_putc(digits[(v >> i) & 0xfu]);
  }
}
