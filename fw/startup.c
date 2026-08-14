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
};

void Reset_Handler(void)
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
