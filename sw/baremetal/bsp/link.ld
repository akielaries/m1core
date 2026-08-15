/* armv6-m blink, code in itcm and data in dtcm */

MEMORY
{
  ITCM (rx)  : ORIGIN = 0x00000000, LENGTH = 32K
  DTCM (rwx) : ORIGIN = 0x20000000, LENGTH = 16K
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
  /* a fixed window at the very bottom of dtcm for test results, so a testbench
     can read them at a known address. it must come before .data and .bss, or
     those get placed on top and the program overwrites its own state as it
     reports */
  .results (NOLOAD) : {
    . = ALIGN(4);
    *(.results)
    . = ALIGN(4);
  } > DTCM

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
