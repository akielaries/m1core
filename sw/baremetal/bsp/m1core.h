/*
 * m1core device header
 *
 * GENERATED from boards/gw5a25/mcu.yaml by tools/m1core_gen.py. Do not edit.
 * Change the SoC description and regenerate, so the RTL, this header and
 * docs/memory-map.md cannot drift apart.
 *
 * Register layouts come from tools/peripherals/<type>.yaml.
 */
#ifndef M1CORE_H
#define M1CORE_H

#include <stdint.h>

/* the fabric clock. software cannot read this back, there is no PLL to
   interrogate: pll from the 50 MHz oscillator, see boards/gw5a25/top.v */
#define SYSTEM_CLOCK_HZ  45000000u

/* address regions */
#define ITCM_BASE          0x00000000u
#define DTCM_BASE          0x20000000u
#define AHB1PERIPH_BASE    0x40000000u
#define APB1PERIPH_BASE    0x50000000u
#define APB2PERIPH_BASE    0x60000000u
#define AHB2PERIPH_BASE    0x80000000u

/*
 * the standard peripheral map, from tools/standard-map.yaml, which is
 * gowin's empu m1 layout. all of it is defined whatever this build
 * actually contains, so bsp and application code can be written once
 * against the standard addresses.
 *
 * M1CORE_HAS_<name> says what is really in this build. a read of a
 * peripheral that is not present returns zero rather than faulting, so
 * check the macro if you need to know.
 */
#define GPIO0_BASE         0x40000000u
#define CAN_BASE           0x45000000u
#define TIMER0_BASE        0x50000000u
#define TIMER1_BASE        0x50001000u
#define DUALTIMER_BASE     0x50002000u
#define SPI_FLASH_BASE     0x50003000u
#define UART0_BASE         0x50004000u
#define UART1_BASE         0x50005000u
#define RTC_BASE           0x50006000u
#define WDOG_BASE          0x50008000u
#define SDCARD_BASE        0x50009000u
#define I2C_BASE           0x5000a000u
#define SPI_BASE           0x5000b000u
#define TRNG_BASE          0x5000f000u

#define M1CORE_HAS_GPIO0       1
#define M1CORE_HAS_CAN         0
#define M1CORE_HAS_TIMER0      1
#define M1CORE_HAS_TIMER1      0
#define M1CORE_HAS_DUALTIMER   0
#define M1CORE_HAS_SPI_FLASH   0
#define M1CORE_HAS_UART0       1
#define M1CORE_HAS_UART1       0
#define M1CORE_HAS_RTC         1
#define M1CORE_HAS_WDOG        0
#define M1CORE_HAS_SDCARD      0
#define M1CORE_HAS_I2C         0
#define M1CORE_HAS_SPI         0
#define M1CORE_HAS_TRNG        0

/* the standard interrupt map. numbering is gowin's, so a handler name
   means the same thing on either core */
typedef enum {
  NonMaskableInt_IRQn = -14,
  HardFault_IRQn      = -13,
  SVCall_IRQn         =  -5,
  PendSV_IRQn         =  -2,
  SysTick_IRQn        =  -1,
  UART0_IRQn       =   0,
  UART1_IRQn       =   1,
  TIMER0_IRQn      =   2,
  TIMER1_IRQn      =   3,
  GPIO0_IRQn       =   4,
  UARTOVF_IRQn     =   5,
  RTC_IRQn         =   6,
  I2C_IRQn         =   7,
  CAN_IRQn         =   8,
  ENT_IRQn         =   9,
  EXTINT_0_IRQn    =  10,
  DTimer_IRQn      =  11,
  TRNG_IRQn        =  12,
  EXTINT_1_IRQn    =  13,
  EXTINT_2_IRQn    =  14,
  EXTINT_3_IRQn    =  15,
  GPIO0_0_IRQn     =  16,
  GPIO0_1_IRQn     =  17,
  GPIO0_2_IRQn     =  18,
  GPIO0_3_IRQn     =  19,
  GPIO0_4_IRQn     =  20,
  GPIO0_5_IRQn     =  21,
  GPIO0_6_IRQn     =  22,
  GPIO0_7_IRQn     =  23,
  GPIO0_8_IRQn     =  24,
  GPIO0_9_IRQn     =  25,
  GPIO0_10_IRQn    =  26,
  GPIO0_11_IRQn    =  27,
  GPIO0_12_IRQn    =  28,
  GPIO0_13_IRQn    =  29,
  GPIO0_14_IRQn    =  30,
  GPIO0_15_IRQn    =  31
} IRQn_Type;

/* simple gpio, data/dir with atomic set and clear */
typedef struct {
  volatile uint32_t DATA;  /* 0x00 current output value */
  volatile uint32_t DIR;   /* 0x04 1 = drive the pin */
  volatile uint32_t SET;   /* 0x08 write ones to set */
  volatile uint32_t CLR;   /* 0x0c write ones to clear */
} gpio_t;

/* single master i2c, one start/byte/stop sequence per command */
typedef struct {
  volatile uint32_t CTRL;       /* 0x00 [0]EN [1]IRQEN */
  volatile uint32_t CMD;        /* 0x04 [0]START [1]STOP [2]WRITE [3]READ [4]ACK */
  volatile uint32_t DATA;       /* 0x08 byte to send, or the byte received */
  volatile uint32_t STATUS;     /* 0x0c [0]BUSY [1]RXACK, 1 means not acked */
  volatile uint32_t CLKDIV;     /* 0x10 scl quarter period in pclk, minus one */
  volatile uint32_t INTSTATUS;  /* 0x14 read pending, write one to clear */
} i2c_t;

/* prescaled tick counter with a match interrupt */
typedef struct {
  volatile uint32_t CTRL;       /* 0x00 [0]EN [1]IRQEN */
  volatile uint32_t COUNT;      /* 0x04 tick counter, writable */
  volatile uint32_t MATCH;      /* 0x08 interrupt when COUNT reaches this */
  volatile uint32_t INTSTATUS;  /* 0x0c read pending, write one to clear */
  volatile uint32_t PRESCALE;   /* 0x10 pclk cycles per tick, minus one */
} rtc_t;

/* spi master, all four modes, msb first, eight bits per transfer */
typedef struct {
  volatile uint32_t CTRL;       /* 0x00 [0]EN [1]CPOL [2]CPHA [3]IRQEN */
  volatile uint32_t STATUS;     /* 0x04 [0]BUSY */
  volatile uint32_t DATA;       /* 0x08 write starts a transfer, read returns rx */
  volatile uint32_t CLKDIV;     /* 0x0c sclk half period in pclk, minus one */
  volatile uint32_t SSEL;       /* 0x10 bit n drives ssel_n[n] low while set */
  volatile uint32_t INTSTATUS;  /* 0x14 read pending, write one to clear */
} spi_t;

/* cmsdk compatible down counting timer */
typedef struct {
  volatile uint32_t CTRL;       /* 0x00 [0]EN [1]SELEXTEN [2]SELEXTCLK [3]IRQEN */
  volatile uint32_t VALUE;      /* 0x04 current value, counts down */
  volatile uint32_t RELOAD;     /* 0x08 loaded when the counter wraps */
  volatile uint32_t INTSTATUS;  /* 0x0c read pending, write one to clear */
} timer_t;

/* cmsdk compatible uart, so GOWIN_M1_uart.c drives it unchanged */
typedef struct {
  volatile uint32_t DATA;       /* 0x00 tx on write, rx on read */
  volatile uint32_t STATE;      /* 0x04 [0]TXBF [1]RXBF [2]TXOR [3]RXOR */
  volatile uint32_t CTRL;       /* 0x08 [0]TXEN [1]RXEN [2]TXIRQEN [3]RXIRQEN */
  volatile uint32_t INTSTATUS;  /* 0x0c read pending, write 1 to clear */
  volatile uint32_t BAUDDIV;    /* 0x10 system clocks per bit, min 16 */
} uart_t;

/* instance pointers */
#define GPIO0      ((gpio_t *)GPIO0_BASE)
#define TIMER0     ((timer_t *)TIMER0_BASE)
#define TIMER1     ((timer_t *)TIMER1_BASE)
#define UART0      ((uart_t *)UART0_BASE)
#define UART1      ((uart_t *)UART1_BASE)
#define RTC        ((rtc_t *)RTC_BASE)
#define I2C        ((i2c_t *)I2C_BASE)
#define SPI        ((spi_t *)SPI_BASE)

/* register bits */
#define I2C_CTRL_EN              (1u << 0)
#define I2C_CTRL_IRQEN           (1u << 1)
#define I2C_CMD_START            (1u << 0)
#define I2C_CMD_STOP             (1u << 1)
#define I2C_CMD_WRITE            (1u << 2)
#define I2C_CMD_READ             (1u << 3)
#define I2C_CMD_ACK              (1u << 4)
#define I2C_STATUS_BUSY          (1u << 0)
#define I2C_STATUS_RXACK         (1u << 1)
#define RTC_CTRL_EN              (1u << 0)
#define RTC_CTRL_IRQEN           (1u << 1)
#define SPI_CTRL_EN              (1u << 0)
#define SPI_CTRL_CPOL            (1u << 1)
#define SPI_CTRL_CPHA            (1u << 2)
#define SPI_CTRL_IRQEN           (1u << 3)
#define SPI_STATUS_BUSY          (1u << 0)
#define TIMER_CTRL_EN            (1u << 0)
#define TIMER_CTRL_SELEXTEN      (1u << 1)
#define TIMER_CTRL_SELEXTCLK     (1u << 2)
#define TIMER_CTRL_IRQEN         (1u << 3)
#define UART_STATE_TXBF          (1u << 0)
#define UART_STATE_RXBF          (1u << 1)
#define UART_STATE_TXOR          (1u << 2)
#define UART_STATE_RXOR          (1u << 3)
#define UART_CTRL_TXEN           (1u << 0)
#define UART_CTRL_RXEN           (1u << 1)
#define UART_CTRL_TXIRQEN        (1u << 2)
#define UART_CTRL_RXIRQEN        (1u << 3)

#endif /* M1CORE_H */
