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

/* external interrupts, the full standard map from tools/standard-map.yaml.
   all thirty two are declared whatever a build contains, so a handler name
   means the same thing on any configuration and on gowin's core. weak, so
   an application defines only the ones it uses */
void UART0_Handler(void)       __attribute__((weak, alias("Default_Handler")));
void UART1_Handler(void)       __attribute__((weak, alias("Default_Handler")));
void TIMER0_Handler(void)      __attribute__((weak, alias("Default_Handler")));
void TIMER1_Handler(void)      __attribute__((weak, alias("Default_Handler")));
void GPIO0_Handler(void)       __attribute__((weak, alias("Default_Handler")));
void UARTOVF_Handler(void)     __attribute__((weak, alias("Default_Handler")));
void RTC_Handler(void)         __attribute__((weak, alias("Default_Handler")));
void I2C_Handler(void)         __attribute__((weak, alias("Default_Handler")));
void CAN_Handler(void)         __attribute__((weak, alias("Default_Handler")));
void ENT_Handler(void)         __attribute__((weak, alias("Default_Handler")));
void EXTINT_0_Handler(void)    __attribute__((weak, alias("Default_Handler")));
void DTimer_Handler(void)      __attribute__((weak, alias("Default_Handler")));
void TRNG_Handler(void)        __attribute__((weak, alias("Default_Handler")));
void EXTINT_1_Handler(void)    __attribute__((weak, alias("Default_Handler")));
void EXTINT_2_Handler(void)    __attribute__((weak, alias("Default_Handler")));
void EXTINT_3_Handler(void)    __attribute__((weak, alias("Default_Handler")));
void GPIO0_0_Handler(void)     __attribute__((weak, alias("Default_Handler")));
void GPIO0_1_Handler(void)     __attribute__((weak, alias("Default_Handler")));
void GPIO0_2_Handler(void)     __attribute__((weak, alias("Default_Handler")));
void GPIO0_3_Handler(void)     __attribute__((weak, alias("Default_Handler")));
void GPIO0_4_Handler(void)     __attribute__((weak, alias("Default_Handler")));
void GPIO0_5_Handler(void)     __attribute__((weak, alias("Default_Handler")));
void GPIO0_6_Handler(void)     __attribute__((weak, alias("Default_Handler")));
void GPIO0_7_Handler(void)     __attribute__((weak, alias("Default_Handler")));
void GPIO0_8_Handler(void)     __attribute__((weak, alias("Default_Handler")));
void GPIO0_9_Handler(void)     __attribute__((weak, alias("Default_Handler")));
void GPIO0_10_Handler(void)    __attribute__((weak, alias("Default_Handler")));
void GPIO0_11_Handler(void)    __attribute__((weak, alias("Default_Handler")));
void GPIO0_12_Handler(void)    __attribute__((weak, alias("Default_Handler")));
void GPIO0_13_Handler(void)    __attribute__((weak, alias("Default_Handler")));
void GPIO0_14_Handler(void)    __attribute__((weak, alias("Default_Handler")));
void GPIO0_15_Handler(void)    __attribute__((weak, alias("Default_Handler")));

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
  CAN_Handler,
  ENT_Handler,
  EXTINT_0_Handler,
  DTimer_Handler,
  TRNG_Handler,
  EXTINT_1_Handler,
  EXTINT_2_Handler,
  EXTINT_3_Handler,
  GPIO0_0_Handler,
  GPIO0_1_Handler,
  GPIO0_2_Handler,
  GPIO0_3_Handler,
  GPIO0_4_Handler,
  GPIO0_5_Handler,
  GPIO0_6_Handler,
  GPIO0_7_Handler,
  GPIO0_8_Handler,
  GPIO0_9_Handler,
  GPIO0_10_Handler,
  GPIO0_11_Handler,
  GPIO0_12_Handler,
  GPIO0_13_Handler,
  GPIO0_14_Handler,
  GPIO0_15_Handler,
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
