/*
 * m1core_demo - m1kern running on the m1core soft core
 *
 * the showcase for this repository rather than for the kernel. it exercises
 * the parts of the soc an rtos actually leans on:
 *
 *   systick    sleeps are timed by it, so the blink rates prove it is 1 kHz
 *   pendsv     the two spinners never yield, they only advance because the
 *              switch is preemptive
 *   nvic       the monitor outranks the spinners and always gets to print
 *   gpio       gpio0 bit 0 at 1 Hz, bit 1 at 2 Hz (LD4 and LD5 on the basys 3)
 *   uart0      the report, 115200 8n1 on the board's usb serial port
 *
 * expected on the uart every second, counts are loop passes in the interval:
 *   [3015 ms] +1004 ms spin0=695125 spin1=705376 share 49%/50%
 * with the two shares staying close to even. per interval rather than totals
 * because the 32-bit counters wrap after about 1.7 hours at 50 MHz, and
 * unsigned subtraction across a wrap still gives the right delta
 */
#include "m1kern.h"
#include "board.h"

static volatile uint32_t spin0_count = 0;
static volatile uint32_t spin1_count = 0;

THREAD_STACK(blink_slow, 256);
THREAD_FUNCTION(blink_slow_fn, arg) {
  while (1) {
    led_toggle(LED0);
    thread_sleep_ms(500);
  }
}

THREAD_STACK(blink_fast, 256);
THREAD_FUNCTION(blink_fast_fn, arg) {
  while (1) {
    led_toggle(LED1);
    thread_sleep_ms(250);
  }
}

THREAD_STACK(spin0, 256);
THREAD_FUNCTION(spin0_fn, arg) {
  while (1) {
    spin0_count++;
  }
}

THREAD_STACK(spin1, 256);
THREAD_FUNCTION(spin1_fn, arg) {
  while (1) {
    spin1_count++;
  }
}

THREAD_STACK(monitor, 512);
THREAD_FUNCTION(monitor_fn, arg) {
  uint32_t last_ms = system_time_ms;
  uint32_t last0   = spin0_count;
  uint32_t last1   = spin1_count;

  while (1) {
    thread_sleep_ms(1000);

    uint32_t now = system_time_ms;
    uint32_t c0  = spin0_count;
    uint32_t c1  = spin1_count;
    uint32_t a   = c0 - last0;
    uint32_t b   = c1 - last1;
    uint32_t total = a + b;

    console_printf("[%u ms] +%u ms spin0=%u spin1=%u", now, now - last_ms, a, b);
    last_ms = now;
    last0   = c0;
    last1   = c1;

    /* divide total down rather than scale the counts up, a * 100 wraps at
       these rates */
    if (total >= 100) {
      console_printf(" share %u%%/%u%%", a / (total / 100), b / (total / 100));
    }
    console_printf("\r\n");
  }
}

int main(void) {
  board_init();
  kernel_init();

  mkthd_static(blink_slow, blink_slow_fn, sizeof(blink_slow), PRIO_NORMAL, NULL);
  mkthd_static(blink_fast, blink_fast_fn, sizeof(blink_fast), PRIO_NORMAL, NULL);
  mkthd_static(spin0, spin0_fn, sizeof(spin0), PRIO_LOW, NULL);
  mkthd_static(spin1, spin1_fn, sizeof(spin1), PRIO_LOW, NULL);
  mkthd_static(monitor, monitor_fn, sizeof(monitor), PRIO_HIGH, NULL);

  console_printf("\r\nm1core_demo: m1kern on m1core, %u Hz\r\n", SYSTEM_CLOCK_HZ);
  kernel_start();
  return 0;
}
