#include "m1core.h"

/* derived from the clock, not a constant: this was 700000 tuned for a 25 mhz
   core and stayed that way through 45, 80 and 50 mhz. /36 is about 200 ms */
#ifndef DELAY_ITERS
#define DELAY_ITERS (SYSTEM_CLOCK_HZ / 36u)
#endif

static void delay(volatile uint32_t n)
{
  while (n--) {
  }
}

int main(void)
{
  GPIO0->DIR = 0x3u;

  /* drive the two pins in opposite phase so a running core is unmistakable:
     one lit at all times, alternating. a stuck core leaves both static */
  for (;;) {
    GPIO0->SET = 0x1u;
    GPIO0->CLR = 0x2u;
    delay(DELAY_ITERS);
    GPIO0->CLR = 0x1u;
    GPIO0->SET = 0x2u;
    delay(DELAY_ITERS);
  }

  return 0;
}
