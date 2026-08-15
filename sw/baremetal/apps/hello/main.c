#include "m1core.h"
#include "uart.h"

/* proves the whole chain: the core fetches and executes, the ahb fabric routes
   to the apb bridge, the bridge completes with wait states, and the uart puts
   real bits on a pin */

/* the loop body is a handful of cycles at 25 mhz, so this lands around a few
   hundred ms per half period. same value blink uses */
#ifndef DELAY_ITERS
#define DELAY_ITERS 700000u
#endif

static void delay(volatile uint32_t n)
{
  while (n--) {
  }
}

int main(void)
{
  uint32_t count = 0;

  uart_init(115200u);
  uart_puts("m1core alive\n");

  GPIO0->DIR = 0x3u;

  /*
   * the two pins run in opposite phase, so a running core is unmistakable on a
   * scope: one is always high and they alternate. without the delay this loop
   * toggles as fast as the uart will accept characters, which reads as a blur
   * rather than a blink
   */
  for (;;) {
    /* one write rather than a SET followed by a CLR: two stores would leave the
       pins briefly in the same state between them, which shows up on a scope */
    GPIO0->DATA = 0x1u;

    uart_puts("tick ");
    uart_puthex(count);
    uart_puts("\n");

    delay(DELAY_ITERS);

    GPIO0->DATA = 0x2u;

    delay(DELAY_ITERS);

    count++;
  }

  return 0;
}
