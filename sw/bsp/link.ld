/* armv6-m blink, code in itcm and data in dtcm */

MEMORY
{
  ITCM (rx)  : ORIGIN = 0x00000000, LENGTH = 16K
  DTCM (rwx) : ORIGIN = 0x20000000, LENGTH = 8K
}

ENTRY(Reset_Handler)

SECTIONS
{
  .isr_vector : {
    KEEP(*(.isr_vector))
  } > ITCM

  .text : {
    *(.text*)
    *(.rodata*)
    . = ALIGN(4);
  } > ITCM

  /* .data is stored in itcm and copied to dtcm by the reset handler, so the
     image stays a single contiguous thing a debugger can load */
  _sidata = LOADADDR(.data);

  .data : {
    . = ALIGN(4);
    _sdata = .;
    *(.data*)
    . = ALIGN(4);
    _edata = .;
  } > DTCM AT > ITCM

  .bss : {
    . = ALIGN(4);
    _sbss = .;
    *(.bss*)
    *(COMMON)
    . = ALIGN(4);
    _ebss = .;
  } > DTCM

  _estack = ORIGIN(DTCM) + LENGTH(DTCM);
}
