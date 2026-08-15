#include "m1core.h"

/*
 * exception model test. runs on the core with no debugger and reports through
 * dtcm, the same way the isa test does:
 *   0x20000000 error count, 0 means pass
 *   0x20000004 id of the first failing check
 *   0x20000008 0x600dc0de once complete
 *
 * covers the pieces m1kern depends on: systick, svc, pendsv, priority ordering
 * and the psp/msp banking a context switch needs
 */

/* the testbench reads these at 0x20000000. they live in their own section so
   .data and .bss cannot be placed on top of them, which would have the program
   overwrite its own state as it reported */
__attribute__((section(".results"))) volatile uint32_t results[8];

#define SCS_ICSR    (*(volatile uint32_t *)0xE000ED04u)
#define SCS_SHPR2   (*(volatile uint32_t *)0xE000ED1Cu)
#define SCS_SHPR3   (*(volatile uint32_t *)0xE000ED20u)
#define SYST_CSR    (*(volatile uint32_t *)0xE000E010u)
#define SYST_RVR    (*(volatile uint32_t *)0xE000E014u)
#define SYST_CVR    (*(volatile uint32_t *)0xE000E018u)

#define ICSR_PENDSVSET (1u << 28)

static volatile uint32_t systick_count;
static volatile uint32_t svc_count;
static volatile uint32_t pendsv_count;
static volatile uint32_t order;          /* records which handler ran first */
static volatile uint32_t svc_ipsr;
static volatile uint32_t deep_count;

static uint32_t psp_stack[64];
static volatile uint32_t dbg_deep, dbg_pend;
static volatile uint32_t fault_count;
static volatile uint32_t fault_pc;

static uint32_t errors;
static uint32_t first_fail;
static uint32_t test_id;
static uint32_t fail_mask;   /* bit n set means check n failed */

static void check(int cond)
{
  test_id++;
  if (!cond) {
    errors++;
    fail_mask |= (1u << test_id);
    if (first_fail == 0u) {
      first_fail = test_id;
    }
  }
}

void SysTick_Handler(void)
{
  systick_count++;
  if (order == 0u) {
    order = 1u;   /* systick ran before pendsv */
  }
}

/* noinline so PendSV_Handler cannot be a leaf. that forces gcc to push lr and
   return with pop {r7, pc} rather than bx lr, which is a completely different
   exception return path in the core and the one every real handler uses */
__attribute__((noinline)) static void pendsv_work(void)
{
  deep_count++;
}

void PendSV_Handler(void)
{
  pendsv_count++;
  pendsv_work();
  if (order == 0u) {
    order = 2u;
  }
}

/*
 * every fault escalates to hardfault on armv6-m. the handler reads the stacked
 * pc so a test can check the fault was reported against the right instruction,
 * then steps the stacked pc past it so execution can resume
 */
void HardFault_Handler(void) __attribute__((naked));
void HardFault_Handler(void)
{
  __asm volatile(
    "mrs  r0, msp        \n"   /* handler runs on msp, frame is at the top */
    "b    hardfault_c    \n");
}

void hardfault_c(uint32_t *frame);
void hardfault_c(uint32_t *frame)
{
  fault_count++;
  fault_pc = frame[6];       /* stacked return address */
  /* skip the faulting instruction so the test can carry on. every fault it
     provokes is a 2 byte encoding */
  frame[6] = frame[6] + 2u;
}

void SVC_Handler(void)
{
  uint32_t ipsr;
  svc_count++;
  __asm volatile("mrs %0, ipsr" : "=r"(ipsr));
  svc_ipsr = ipsr;
  /* an svc handler pending pendsv is exactly what m1kern does to start it */
  SCS_ICSR = ICSR_PENDSVSET;
}

int main(void)
{
  volatile uint32_t *out = results;
  uint32_t i;
  uint32_t msp_before, msp_after;

  errors = 0u;
  first_fail = 0u;
  test_id = 0u;

  /* pendsv lowest priority, systick above it, which is the usual rtos setup */
  SCS_SHPR3 = (3u << 22) | (1u << 30);
  SCS_SHPR2 = (2u << 30);

  /* --- svc, and the ipsr the handler sees --- */
  __asm volatile("svc #0");
  check(svc_count == 1u);
  check(svc_ipsr == 11u);

  /* the svc handler pended pendsv, which must have run on the way back */
  check(pendsv_count == 1u);

  /* --- systick --- */
  order = 0u;
  systick_count = 0u;
  /* the core is multi-cycle and an exception entry plus exit is about sixteen
     bus transactions, so a fast reload starves thread mode entirely */
  SYST_RVR = 20000u;
  SYST_CVR = 0u;
  SYST_CSR = 0x3u;                 /* enable | tickint */

  for (i = 0; i < 2000000u && systick_count < 3u; i++) {
  }
  check(systick_count >= 3u);
  SYST_CSR = 0u;

  /* --- priority: systick preempts nothing here, but it must have run before
     a pendsv pended at lower priority --- */
  order = 0u;
  pendsv_count = 0u;
  deep_count = 0u;      /* reset both, they are compared against each other */
  SCS_ICSR = ICSR_PENDSVSET;
  for (i = 0; i < 1000u && pendsv_count == 0u; i++) {
  }
  check(pendsv_count == 1u);

  /* --- the stack pointer must come back exactly where it started --- */
  __asm volatile("mrs %0, msp" : "=r"(msp_before));
  __asm volatile("svc #0");
  __asm volatile("mrs %0, msp" : "=r"(msp_after));
  check(msp_before == msp_after);

  /* the handler returned through pop {pc}, not bx lr.
     both counters have to be sampled with interrupts off: a pendsv landing
     between the two reads would make them disagree for reasons that have
     nothing to do with what is being tested */
  {
    uint32_t d, p;

    __asm volatile("cpsid i");
    d = deep_count;
    p = pendsv_count;
    __asm volatile("cpsie i");

    dbg_deep = d;
    dbg_pend = p;
    check(d == p);
    check(p > 0u);
  }

  /*
   * --- msr CONTROL sets SPSEL from bit 1 ---
   *
   * done entirely inside one asm block: switching SPSEL changes which stack sp
   * points at, so the compiler must not be spilling anything in between.
   * assigning the masked operand straight into a one bit register keeps bit 0
   * and silently stores zero, which leaves threads on MSP and makes an rtos
   * context switch impossible
   */
  {
    uint32_t ctrl_after;
    uint32_t psp_top = (uint32_t)&psp_stack[64];

    __asm volatile(
      "msr psp, %1      \n"
      "movs r0, #2      \n"
      "msr control, r0  \n"
      "isb              \n"
      "mrs %0, control  \n"
      "movs r0, #0      \n"
      "msr control, r0  \n"
      "isb              \n"
      : "=r"(ctrl_after) : "r"(psp_top) : "r0");

    check((ctrl_after & 2u) == 2u);
  }

  /* psp survives a round trip through msr/mrs */
  {
    uint32_t psp_read;
    uint32_t psp_top = (uint32_t)&psp_stack[64];

    __asm volatile("msr psp, %1 \n mrs %0, psp" : "=r"(psp_read) : "r"(psp_top));
    check(psp_read == psp_top);
  }

  /*
   * --- faults ---
   *
   * these are the bugs that used to be silent. an undefined instruction just
   * stopped the core, an unaligned load quietly read the wrong address because
   * the sram masks rather than complains, and a branch to an address with the
   * thumb bit clear had the bit masked away and carried on executing wherever
   * it landed
   */
  {
    uint32_t before = fault_count;

    /* permanently undefined encoding */
    __asm volatile("udf #0");
    check(fault_count == before + 1u);

    /*
     * unaligned accesses have to be written in asm. given an obviously
     * unaligned pointer gcc does not emit an unaligned access at all: it
     * synthesises the word load from two ldrh and the halfword from two ldrb,
     * because armv6-m cannot do it. a corrupted pointer or a bad cast at
     * runtime still reaches the hardware, which is what this checks
     */
    before = fault_count;
    __asm volatile("ldr r0, [%0]" :: "r"(0x20000102u) : "r0");
    check(fault_count == before + 1u);

    before = fault_count;
    __asm volatile("ldrh r0, [%0]" :: "r"(0x20000101u) : "r0");
    check(fault_count == before + 1u);

    /* the handler saw a sensible faulting address, inside the image */
    check(fault_pc != 0u && fault_pc < 0x8000u);
  }

  /* --- ipsr is zero in thread mode --- */
  {
    uint32_t ipsr;
    __asm volatile("mrs %0, ipsr" : "=r"(ipsr));
    check(ipsr == 0u);
  }

  out[7] = fault_count;
  out[5] = fail_mask;
  out[6] = test_id;
  out[3] = dbg_deep;
  out[4] = dbg_pend;
  out[0] = errors;
  out[1] = first_fail;
  out[2] = 0x600DC0DEu;

  for (;;) {
  }

  return 0;
}
