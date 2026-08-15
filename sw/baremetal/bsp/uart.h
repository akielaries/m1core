#ifndef BSP_UART_H
#define BSP_UART_H

#include <stdint.h>

/*
 * uart driver prototypes. these are board support, not device description, so
 * they live here rather than in the generated m1core.h
 */
void uart_init(uint32_t baud);
void uart_putc(char c);
void uart_puts(const char *s);
void uart_puthex(uint32_t v);

#endif
