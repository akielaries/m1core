#ifndef SOC_H
#define SOC_H

#include <stdint.h>

/* memory map, matches rtl/soc/ahb_fabric.sv */
#define ITCM_BASE 0x00000000u
#define DTCM_BASE 0x20000000u
#define GPIO_BASE 0x40000000u

typedef struct {
  volatile uint32_t DATA;  /* current output value */
  volatile uint32_t DIR;   /* 1 = drive the pin */
  volatile uint32_t SET;   /* write ones to set */
  volatile uint32_t CLR;   /* write ones to clear */
} gpio_t;

#define GPIO ((gpio_t *)GPIO_BASE)

#endif
