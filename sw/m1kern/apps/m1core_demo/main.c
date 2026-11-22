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
 * expected on the uart every second:
 *   [  3000 ms] spin0=... spin1=... share 50%/50%
 * with the two shares staying close to even
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
  while (1) {
    thread_sleep_ms(1000);

    uint32_t a = spin0_count;
    uint32_t b = spin1_count;
    uint32_t total = a + b;

    console_printf("[%u ms] spin0=%u spin1=%u", system_time_ms, a, b);
    /* divide total down rather than scale the counts up, a * 100 wraps within
       a minute at 50 MHz */
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
