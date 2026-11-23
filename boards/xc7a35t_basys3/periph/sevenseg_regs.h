#ifndef __CHEBY__SEVENSEG_REGS__H__
#define __CHEBY__SEVENSEG_REGS__H__

#define SEVENSEG_REGS_SIZE 16 /* 0x10 */

/* REG ctrl */
#define SEVENSEG_REGS_CTRL 0x0UL
#define SEVENSEG_REGS_CTRL_EN 0x1UL
#define SEVENSEG_REGS_CTRL_EN_MASK 0x1UL
#define SEVENSEG_REGS_CTRL_EN_SHIFT 0
#define SEVENSEG_REGS_CTRL_RAW 0x2UL
#define SEVENSEG_REGS_CTRL_RAW_MASK 0x2UL
#define SEVENSEG_REGS_CTRL_RAW_SHIFT 1

/* REG value */
#define SEVENSEG_REGS_VALUE 0x4UL
#define SEVENSEG_REGS_VALUE_DIGITS_MASK 0xffffUL
#define SEVENSEG_REGS_VALUE_DIGITS_SHIFT 0

/* REG raw */
#define SEVENSEG_REGS_RAW 0x8UL
#define SEVENSEG_REGS_RAW_SEGS_MASK 0xffffffffUL
#define SEVENSEG_REGS_RAW_SEGS_SHIFT 0

/* REG dp */
#define SEVENSEG_REGS_DP 0xcUL
#define SEVENSEG_REGS_DP_MASK_MASK 0xfUL
#define SEVENSEG_REGS_DP_MASK_SHIFT 0

#ifndef __ASSEMBLER__
struct sevenseg_regs {
  /* [0x0]: REG (rw) */
  uint32_t ctrl;

  /* [0x4]: REG (rw) */
  uint32_t value;

  /* [0x8]: REG (rw) */
  uint32_t raw;

  /* [0xc]: REG (rw) */
  uint32_t dp;
};
#endif /* !__ASSEMBLER__*/

#endif /* __CHEBY__SEVENSEG_REGS__H__ */
