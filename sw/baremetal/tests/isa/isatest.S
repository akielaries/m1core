@ self checking armv6-m instruction test
@
@ runs on the core with no debugger involved. every check is a cmp followed by
@ CHECK, which counts failures and remembers the first failing test id. long
@ branches to a shared fail label are deliberately avoided because a thumb
@ conditional branch only reaches +-256 bytes
@
@ results, at the bottom of dtcm:
@   0x20000000  error count, 0 means pass
@   0x20000004  id of the first failing test, 0 if none
@   0x20000008  0x600dc0de once the test has run to completion
@
@ register budget: r4 first failure id, r6 error count, r7 test id.
@ tests use r0-r3

  .syntax unified
  .cpu cortex-m1
  .thumb

  .section .isr_vector, "a"
  .word 0x20002000
  .word reset + 1

  .text
  .align 2

@ bump the test id
  .macro T
  adds r7, #1
  .endm

@ emit a literal pool and branch over it. a bare .ltorg here would drop data
@ right on the label CHECK branches to, and execution would run into it
  .macro POOL
  b    8f
  .ltorg
8:
  .endm

@ consume the flags from the preceding cmp
  .macro CHECK
  beq  9f
  adds r6, #1
  cmp  r4, #0
  bne  9f
  movs r4, r7
9:
  .endm

  .thumb_func
  .global reset
reset:
  movs r4, #0
  movs r6, #0
  movs r7, #0

  @ --- movs / adds / subs immediate ---
  T
  movs r0, #5
  adds r0, #3
  cmp  r0, #8
  CHECK

  T
  movs r0, #10
  subs r0, #4
  cmp  r0, #6
  CHECK

  @ --- adds / subs register and imm3 ---
  T
  movs r0, #20
  movs r1, #7
  subs r2, r0, r1
  cmp  r2, #13
  CHECK

  T
  adds r2, r0, r1
  cmp  r2, #27
  CHECK

  T
  adds r1, r0, #5
  cmp  r1, #25
  CHECK

  T
  subs r1, r0, #3
  cmp  r1, #17
  CHECK

  @ --- shifts by immediate ---
  T
  movs r0, #1
  lsls r1, r0, #4
  cmp  r1, #16
  CHECK

  T
  movs r0, #128
  lsrs r1, r0, #3
  cmp  r1, #16
  CHECK

  T
  ldr  r0, =0xfffffff0
  asrs r1, r0, #4
  ldr  r2, =0xffffffff
  cmp  r1, r2
  CHECK

  POOL

  @ --- logical operations, two operand forms ---
  T
  ldr  r0, =0xf0f0f0f0
  ldr  r1, =0x0ff00ff0
  ands r0, r1
  ldr  r2, =0x00f000f0
  cmp  r0, r2
  CHECK

  T
  ldr  r0, =0xf0f0f0f0
  ldr  r1, =0x0f0f0f0f
  orrs r0, r1
  ldr  r2, =0xffffffff
  cmp  r0, r2
  CHECK

  T
  ldr  r0, =0xff00ff00
  ldr  r1, =0x0f0f0f0f
  eors r0, r1
  ldr  r2, =0xf00ff00f
  cmp  r0, r2
  CHECK

  POOL

  T
  ldr  r0, =0xffffffff
  ldr  r1, =0x0000ff00
  bics r0, r1
  ldr  r2, =0xffff00ff
  cmp  r0, r2
  CHECK

  T
  movs r0, #0
  mvns r0, r0
  ldr  r2, =0xffffffff
  cmp  r0, r2
  CHECK

  T
  movs r0, #7
  movs r1, #6
  muls r0, r1, r0
  cmp  r0, #42
  CHECK

  T
  movs r0, #5
  negs r0, r0
  adds r0, #5
  cmp  r0, #0
  CHECK

  POOL

  @ --- shifts by register, including the over-32 cases ---
  T
  movs r0, #1
  movs r1, #33
  lsls r0, r1
  cmp  r0, #0
  CHECK

  T
  ldr  r0, =0x80000000
  movs r1, #31
  lsrs r0, r1
  cmp  r0, #1
  CHECK

  T
  ldr  r0, =0x80000001
  movs r1, #4
  rors r0, r1
  ldr  r2, =0x18000000
  cmp  r0, r2
  CHECK

  POOL

  @ --- carry propagation through adc and sbc ---
  T
  ldr  r0, =0xffffffff
  movs r1, #1
  adds r0, r0, r1     @ sets carry
  movs r2, #0
  movs r3, #0
  adcs r2, r3         @ 0 + 0 + carry
  cmp  r2, #1
  CHECK

  T
  movs r0, #5
  movs r1, #3
  subs r0, r0, r1     @ carry set, no borrow
  movs r2, #10
  movs r3, #4
  sbcs r2, r3         @ 10 - 4 - 0
  cmp  r2, #6
  CHECK

  @ --- extends ---
  T
  ldr  r0, =0x000080ff
  sxtb r1, r0
  ldr  r2, =0xffffffff
  cmp  r1, r2
  CHECK

  T
  ldr  r0, =0x0000ffff
  sxth r1, r0
  ldr  r2, =0xffffffff
  cmp  r1, r2
  CHECK

  T
  ldr  r0, =0xffffff81
  uxtb r1, r0
  cmp  r1, #129
  CHECK

  T
  ldr  r0, =0xffff1234
  uxth r1, r0
  ldr  r2, =0x00001234
  cmp  r1, r2
  CHECK

  POOL

  @ --- byte reverse ---
  T
  ldr  r0, =0x11223344
  rev  r1, r0
  ldr  r2, =0x44332211
  cmp  r1, r2
  CHECK

  T
  ldr  r0, =0x11223344
  rev16 r1, r0
  ldr  r2, =0x22114433
  cmp  r1, r2
  CHECK

  POOL

  @ --- loads and stores, all widths ---
  T
  ldr  r3, =0x20000100
  ldr  r0, =0xdeadbeef
  str  r0, [r3]
  ldr  r1, [r3]
  cmp  r1, r0
  CHECK

  T
  movs r0, #0xab
  strb r0, [r3, #4]
  ldrb r1, [r3, #4]
  cmp  r1, #0xab
  CHECK

  T
  ldr  r0, =0x1234
  strh r0, [r3, #8]
  ldrh r1, [r3, #8]
  ldr  r2, =0x1234
  cmp  r1, r2
  CHECK

  @ a stored 0xff must sign extend to -1 when read back with ldrsb
  T
  movs r0, #0xff
  strb r0, [r3, #12]
  movs r0, #12
  ldrsb r1, [r3, r0]
  ldr  r2, =0xffffffff
  cmp  r1, r2
  CHECK

  T
  ldr  r0, =0x8000
  strh r0, [r3, #16]
  movs r0, #16
  ldrsh r1, [r3, r0]
  ldr  r2, =0xffff8000
  cmp  r1, r2
  CHECK

  POOL

  @ --- byte lane placement, the part most likely to be wrong ---
  T
  ldr  r3, =0x20000120
  ldr  r0, =0x00000000
  str  r0, [r3]
  movs r0, #0x5a
  strb r0, [r3, #1]
  ldr  r1, [r3]
  ldr  r2, =0x00005a00
  cmp  r1, r2
  CHECK

  T
  ldr  r0, =0x1234
  strh r0, [r3, #2]
  ldr  r1, [r3]
  ldr  r2, =0x12345a00
  cmp  r1, r2
  CHECK

  POOL

  @ --- push and pop ---
  T
  movs r0, #0x11
  movs r1, #0x22
  push {r0, r1}
  movs r0, #0
  movs r1, #0
  pop  {r0, r1}
  cmp  r0, #0x11
  CHECK

  T
  cmp  r1, #0x22
  CHECK

  @ --- stmia and ldmia with base writeback ---
  T
  ldr  r3, =0x20000140
  movs r0, #0xaa
  movs r1, #0xbb
  movs r2, #0xcc
  stmia r3!, {r0, r1, r2}
  ldr  r0, =0x2000014c
  cmp  r3, r0             @ stmia must write the base back
  CHECK

  T
  ldr  r3, =0x20000140
  movs r0, #0
  movs r1, #0
  movs r2, #0
  ldmia r3!, {r0, r1, r2}
  cmp  r0, #0xaa
  CHECK

  T
  cmp  r2, #0xcc
  CHECK

  T
  ldr  r0, =0x2000014c
  cmp  r3, r0
  CHECK

  POOL

  @ --- conditional branches ---
  T
  movs r0, #5
  cmp  r0, #5
  bne  1f
  movs r1, #1
  b    2f
1:
  movs r1, #0
2:
  cmp  r1, #1
  CHECK

  T
  movs r0, #1
  cmp  r0, #2
  bhs  3f
  movs r1, #1
  b    4f
3:
  movs r1, #0
4:
  cmp  r1, #1
  CHECK

  @ signed comparison, where a naive unsigned implementation breaks
  T
  ldr  r0, =0xffffffff     @ -1
  movs r1, #1
  cmp  r0, r1
  blt  5f
  movs r2, #0
  b    6f
5:
  movs r2, #1
6:
  cmp  r2, #1
  CHECK

  POOL

  @ --- bl and bx lr ---
  T
  movs r0, #4
  bl   times_three
  cmp  r0, #12
  CHECK

  @ --- high register access ---
  T
  movs r0, #0x33
  mov  r8, r0
  movs r1, #0
  mov  r1, r8
  cmp  r1, #0x33
  CHECK

  @ --- sp adjustment and sp relative access ---
  T
  sub  sp, #16
  movs r0, #0x77
  str  r0, [sp, #4]
  ldr  r1, [sp, #4]
  add  sp, #16
  cmp  r1, #0x77
  CHECK

  @ sp itself has to be checked. a decode bug that turned sub sp into a nop
  @ still passed the load/store test above, because add sp merely put sp back
  @ somewhere else
  T
  mov  r0, sp
  sub  sp, #16
  mov  r1, sp
  add  sp, #16
  mov  r2, sp
  cmp  r0, r2
  CHECK

  T
  subs r0, r0, r1
  cmp  r0, #16
  CHECK

  @ revsh, the third op in the misc block that a too-narrow decode mask hides
  T
  ldr  r0, =0x00000087
  revsh r1, r0
  ldr  r2, =0xffff8700
  cmp  r1, r2
  CHECK

  @ --- adr, pc relative address generation ---
  T
  adr  r0, anchor
  ldr  r1, [r0]
  ldr  r2, =0xa5a5a5a5
  cmp  r1, r2
  CHECK

  POOL

done:
  ldr  r3, =0x20000000
  str  r6, [r3]            @ error count
  str  r4, [r3, #4]        @ first failing test id
  ldr  r0, =0x600dc0de
  str  r0, [r3, #8]        @ completion marker
stop:
  b    stop

  .thumb_func
times_three:
  lsls r1, r0, #1
  adds r0, r0, r1
  bx   lr

  .align 2
anchor:
  .word 0xa5a5a5a5

  .ltorg
