#include "soc.h"

/* the tang primer 25k board divides its 50 mhz oscillator by two, so the core
   runs at 25 mhz. the loop body is a handful of cycles, so this lands around a
   few hundred ms per toggle */
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
  GPIO->DIR = 0x3u;

  /* drive the two pins in opposite phase so a running core is unmistakable:
     one lit at all times, alternating. a stuck core leaves both static */
  for (;;) {
    GPIO->SET = 0x1u;
    GPIO->CLR = 0x2u;
    delay(DELAY_ITERS);
    GPIO->CLR = 0x1u;
    GPIO->SET = 0x2u;
    delay(DELAY_ITERS);
  }

  return 0;
}
