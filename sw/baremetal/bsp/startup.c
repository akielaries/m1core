#include <stdint.h>

extern uint32_t _sidata, _sdata, _edata, _sbss, _ebss, _estack;

int main(void);

void Reset_Handler(void);

/* armv6-m has no configurable fault handlers, everything escalates to hardfault */
static void Default_Handler(void)
{
  for (;;) {
  }
}

void NMI_Handler(void)       __attribute__((weak, alias("Default_Handler")));
void HardFault_Handler(void) __attribute__((weak, alias("Default_Handler")));
void SVC_Handler(void)       __attribute__((weak, alias("Default_Handler")));
void PendSV_Handler(void)    __attribute__((weak, alias("Default_Handler")));
void SysTick_Handler(void)   __attribute__((weak, alias("Default_Handler")));

/* external interrupts. numbering matches the mcu description, see
   docs/memory-map.md. weak so an application defines only what it uses */
void UART0_Handler(void)     __attribute__((weak, alias("Default_Handler")));
void UART1_Handler(void)     __attribute__((weak, alias("Default_Handler")));
void TIMER0_Handler(void)    __attribute__((weak, alias("Default_Handler")));
void TIMER1_Handler(void)    __attribute__((weak, alias("Default_Handler")));
void GPIO0_Handler(void)     __attribute__((weak, alias("Default_Handler")));
void UARTOVF_Handler(void)   __attribute__((weak, alias("Default_Handler")));
void RTC_Handler(void)       __attribute__((weak, alias("Default_Handler")));
void I2C_Handler(void)       __attribute__((weak, alias("Default_Handler")));

/* armv6-m vector table, 16 system entries then the irqs */
__attribute__((section(".isr_vector"), used))
void (*const vector_table[])(void) = {
  (void (*)(void))&_estack,
  Reset_Handler,
  NMI_Handler,
  HardFault_Handler,
  0, 0, 0, 0, 0, 0, 0,
  SVC_Handler,
  0, 0,
  PendSV_Handler,
  SysTick_Handler,

  /* external interrupts start here, exception number 16 onward */
  UART0_Handler,
  UART1_Handler,
  TIMER0_Handler,
  TIMER1_Handler,
  GPIO0_Handler,
  UARTOVF_Handler,
  RTC_Handler,
  I2C_Handler,
};

/* the C body of reset. entered with a valid stack, see Reset_Handler below */
void reset_main(void);

/*
 * cortex-m takes the initial sp from vector table word 0, but that only happens
 * on a hardware reset. gdb's load sets pc to the elf entry point and nothing
 * else, so a load followed by continue starts executing with whatever sp was
 * left over from before.
 *
 * that is why load+continue "just works" on microblaze and on a/r profile arm:
 * those initialise sp in crt0 software. cortex-m is the odd one out. setting sp
 * explicitly here makes continue behave the same way, and costs two
 * instructions on a real reset where it is merely redundant.
 */
__attribute__((naked, noreturn)) void Reset_Handler(void)
{
  __asm volatile(
    "ldr r0, =_estack \n"
    "mov sp, r0       \n"
    "bl  reset_main   \n"
    "b   .            \n"
  );
}

void reset_main(void)
{
  uint32_t *src = &_sidata;
  uint32_t *dst = &_sdata;

  while (dst < &_edata) {
    *dst++ = *src++;
  }

  for (dst = &_sbss; dst < &_ebss; dst++) {
    *dst = 0;
  }

  main();

  for (;;) {
  }
}
