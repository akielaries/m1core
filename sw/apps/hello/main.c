#include "soc.h"

/* proves the whole chain: the core fetches and executes, the ahb fabric routes
   to the apb bridge, the bridge completes with wait states, and the uart puts
   real bits on a pin */
int main(void)
{
  uint32_t count = 0;

  uart_init(115200u);
  uart_puts("m1core alive\n");

  GPIO->DIR = 0x3u;

  for (;;) {
    uart_puts("tick ");
    uart_puthex(count);
    uart_puts("\n");

    GPIO->DATA = (count & 1u) ? 0x1u : 0x2u;
    count++;
  }

  return 0;
}
