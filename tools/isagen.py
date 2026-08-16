#!/usr/bin/env python3
"""randomised armv6-m instruction test generator with its own reference model

the hand written isatest.S covers 341 instructions. that is a bring up test: it
proves each encoding was implemented at all, and it was written by reading the
same architecture reference manual the rtl was written from, so a
misunderstanding lands in both and cancels out.

this is the other kind of test. the model below is an independent
implementation of the instruction semantics, written from the flag rules rather
than from the rtl, and the generator emits random programs plus the state the
model says they should end in. a disagreement means one of the two is wrong,
and neither gets to be the definition of correct.

the edge cases this is really aimed at are the shift and carry rules, because
that is where the manual is fiddly and where reading it twice the same wrong way
is easiest:

  LSL #0        leaves C alone rather than clearing it
  LSR #0        means shift by 32, not by nothing
  ASR #0        likewise
  LSL rs        with rs >= 32 clears the result, and C comes from bit 0 or 0
  ROR rs        with rs a multiple of 32 keeps the value but still sets C
  ANDS and MULS set N and Z but must leave C and V untouched

usage:
    python3 tools/isagen.py --blocks 40 --len 12 --seed 1 -o <file.S>
"""

import argparse
import os
import random

M32 = 0xFFFFFFFF


def u32(v):
    return v & M32


def s32(v):
    v &= M32
    return v - (1 << 32) if v & 0x80000000 else v


class Model:
    """armv6-m integer core: r0-r7 and the four condition flags"""

    def __init__(self, regs, flags):
        self.r = list(regs)
        self.n, self.z, self.c, self.v = flags

    def state(self):
        # apsr as the hardware reports it through mrs
        apsr = (self.n << 31) | (self.z << 30) | (self.c << 29) | (self.v << 28)
        return [apsr] + self.r

    # -- flag helpers -----------------------------------------------------
    def _nz(self, res):
        self.n = 1 if res & 0x80000000 else 0
        self.z = 1 if res == 0 else 0

    def _addc(self, a, b, cin):
        """add with carry, returning result and setting all four flags"""
        us = (a & M32) + (b & M32) + cin
        ss = s32(a) + s32(b) + cin
        res = u32(us)
        self._nz(res)
        self.c = 1 if us > M32 else 0
        self.v = 0 if -(1 << 31) <= ss <= (1 << 31) - 1 else 1
        return res

    # -- instructions -----------------------------------------------------
    def movs_imm(self, d, imm):
        self.r[d] = imm
        self._nz(imm)

    def adds_imm(self, d, n, imm):
        self.r[d] = self._addc(self.r[n], imm, 0)

    def subs_imm(self, d, n, imm):
        self.r[d] = self._addc(self.r[n], u32(~imm), 1)

    def adds_reg(self, d, n, m):
        self.r[d] = self._addc(self.r[n], self.r[m], 0)

    def subs_reg(self, d, n, m):
        self.r[d] = self._addc(self.r[n], u32(~self.r[m]), 1)

    def adcs(self, d, m):
        self.r[d] = self._addc(self.r[d], self.r[m], self.c)

    def sbcs(self, d, m):
        self.r[d] = self._addc(self.r[d], u32(~self.r[m]), self.c)

    def negs(self, d, m):
        self.r[d] = self._addc(0, u32(~self.r[m]), 1)

    def cmp_reg(self, n, m):
        self._addc(self.r[n], u32(~self.r[m]), 1)

    def cmp_imm(self, n, imm):
        self._addc(self.r[n], u32(~imm), 1)

    def cmn_reg(self, n, m):
        self._addc(self.r[n], self.r[m], 0)

    # logical: N and Z only, C and V survive untouched
    def ands(self, d, m):
        self.r[d] = u32(self.r[d] & self.r[m]); self._nz(self.r[d])

    def eors(self, d, m):
        self.r[d] = u32(self.r[d] ^ self.r[m]); self._nz(self.r[d])

    def orrs(self, d, m):
        self.r[d] = u32(self.r[d] | self.r[m]); self._nz(self.r[d])

    def bics(self, d, m):
        self.r[d] = u32(self.r[d] & ~self.r[m]); self._nz(self.r[d])

    def mvns(self, d, m):
        self.r[d] = u32(~self.r[m]); self._nz(self.r[d])

    def tst(self, n, m):
        self._nz(u32(self.r[n] & self.r[m]))

    def muls(self, d, m):
        self.r[d] = u32(self.r[d] * self.r[m]); self._nz(self.r[d])

    # shifts: N, Z and C. V is not touched
    def lsls_imm(self, d, m, sh):
        v = self.r[m]
        if sh:                                  # sh == 0 leaves C alone
            self.c = (v >> (32 - sh)) & 1
            v = u32(v << sh)
        self.r[d] = v
        self._nz(v)

    def lsrs_imm(self, d, m, sh):
        v = self.r[m]
        sh = sh or 32                           # encoded 0 means 32
        self.c = (v >> (sh - 1)) & 1 if sh <= 32 else 0
        v = 0 if sh >= 32 else u32(v >> sh)
        self.r[d] = v
        self._nz(v)

    def asrs_imm(self, d, m, sh):
        v = self.r[m]
        sh = sh or 32
        if sh >= 32:
            self.c = (v >> 31) & 1
            v = M32 if v & 0x80000000 else 0
        else:
            self.c = (v >> (sh - 1)) & 1
            v = u32(s32(v) >> sh)
        self.r[d] = v
        self._nz(v)

    def lsls_reg(self, d, s):
        n = self.r[s] & 0xFF
        v = self.r[d]
        if n == 0:
            pass                                # value and C both unchanged
        elif n < 32:
            self.c = (v >> (32 - n)) & 1
            v = u32(v << n)
        elif n == 32:
            self.c = v & 1
            v = 0
        else:
            self.c = 0
            v = 0
        self.r[d] = v
        self._nz(v)

    def lsrs_reg(self, d, s):
        n = self.r[s] & 0xFF
        v = self.r[d]
        if n == 0:
            pass
        elif n < 32:
            self.c = (v >> (n - 1)) & 1
            v = u32(v >> n)
        elif n == 32:
            self.c = (v >> 31) & 1
            v = 0
        else:
            self.c = 0
            v = 0
        self.r[d] = v
        self._nz(v)

    def asrs_reg(self, d, s):
        n = self.r[s] & 0xFF
        v = self.r[d]
        if n == 0:
            pass
        elif n < 32:
            self.c = (v >> (n - 1)) & 1
            v = u32(s32(v) >> n)
        else:
            self.c = (v >> 31) & 1
            v = M32 if v & 0x80000000 else 0
        self.r[d] = v
        self._nz(v)

    def rors_reg(self, d, s):
        n = self.r[s] & 0xFF
        v = self.r[d]
        if n == 0:
            pass
        elif n & 31 == 0:                       # full turns: value stays, C set
            self.c = (v >> 31) & 1
        else:
            k = n & 31
            self.c = (v >> (k - 1)) & 1
            v = u32((v >> k) | (v << (32 - k)))
        self.r[d] = v
        self._nz(v)

    # extends and reverses touch no flags
    def sxtb(self, d, m):
        b = self.r[m] & 0xFF
        self.r[d] = u32(b - 0x100 if b & 0x80 else b)

    def sxth(self, d, m):
        h = self.r[m] & 0xFFFF
        self.r[d] = u32(h - 0x10000 if h & 0x8000 else h)

    def uxtb(self, d, m):
        self.r[d] = self.r[m] & 0xFF

    def uxth(self, d, m):
        self.r[d] = self.r[m] & 0xFFFF

    def rev(self, d, m):
        v = self.r[m]
        self.r[d] = u32(((v & 0xFF) << 24) | ((v & 0xFF00) << 8) |
                        ((v >> 8) & 0xFF00) | ((v >> 24) & 0xFF))

    def rev16(self, d, m):
        v = self.r[m]
        self.r[d] = u32(((v & 0x00FF00FF) << 8) | ((v >> 8) & 0x00FF00FF))

    def revsh(self, d, m):
        v = self.r[m]
        h = u32(((v & 0xFF) << 8) | ((v >> 8) & 0xFF))
        self.r[d] = u32(h - 0x10000 if h & 0x8000 else h)


# every entry is (assembly text, model call). kept as one table so adding an
# instruction means adding it in exactly one place
def pick(rng):
    d, n, m, s = (rng.randrange(8) for _ in range(4))
    imm3, imm8 = rng.randrange(8), rng.randrange(256)

    # lsl immediate is 0..31, and #0 is the movs encoding: value copied, N and
    # Z set, C left alone. lsr and asr are 1..32 in UAL, and shift-by-32 must
    # be written #32. writing #0 there does not mean 32, the assembler turns it
    # into movs, which is a different instruction with different flag rules.
    # generating #0 for them was the first thing this test caught, in itself
    sh_lsl = rng.randrange(32)
    sh_lsr = rng.randrange(1, 33)
    sh_asr = rng.randrange(1, 33)

    # shift amounts around the boundaries far more often than uniformly: 0, 1,
    # 31, 32 and 33 are where the rules stop being uniform
    def shift_src():
        return rng.choice([0, 1, 31, 32, 33, rng.randrange(256)])

    cands = [
        (f"movs r{d}, #{imm8}",          lambda M: M.movs_imm(d, imm8)),
        (f"adds r{d}, r{n}, #{imm3}",    lambda M: M.adds_imm(d, n, imm3)),
        (f"subs r{d}, r{n}, #{imm3}",    lambda M: M.subs_imm(d, n, imm3)),
        (f"adds r{d}, #{imm8}",          lambda M: M.adds_imm(d, d, imm8)),
        (f"subs r{d}, #{imm8}",          lambda M: M.subs_imm(d, d, imm8)),
        (f"adds r{d}, r{n}, r{m}",       lambda M: M.adds_reg(d, n, m)),
        (f"subs r{d}, r{n}, r{m}",       lambda M: M.subs_reg(d, n, m)),
        (f"adcs r{d}, r{m}",             lambda M: M.adcs(d, m)),
        (f"sbcs r{d}, r{m}",             lambda M: M.sbcs(d, m)),
        (f"rsbs r{d}, r{m}, #0",         lambda M: M.negs(d, m)),
        (f"ands r{d}, r{m}",             lambda M: M.ands(d, m)),
        (f"eors r{d}, r{m}",             lambda M: M.eors(d, m)),
        (f"orrs r{d}, r{m}",             lambda M: M.orrs(d, m)),
        (f"bics r{d}, r{m}",             lambda M: M.bics(d, m)),
        (f"mvns r{d}, r{m}",             lambda M: M.mvns(d, m)),
        (f"muls r{d}, r{m}, r{d}",       lambda M: M.muls(d, m)),
        (f"cmp r{n}, r{m}",              lambda M: M.cmp_reg(n, m)),
        (f"cmp r{n}, #{imm8}",           lambda M: M.cmp_imm(n, imm8)),
        (f"cmn r{n}, r{m}",              lambda M: M.cmn_reg(n, m)),
        (f"tst r{n}, r{m}",              lambda M: M.tst(n, m)),
        (f"lsls r{d}, r{m}, #{sh_lsl}",  lambda M: M.lsls_imm(d, m, sh_lsl)),
        (f"lsrs r{d}, r{m}, #{sh_lsr}",  lambda M: M.lsrs_imm(d, m, sh_lsr)),
        (f"asrs r{d}, r{m}, #{sh_asr}",  lambda M: M.asrs_imm(d, m, sh_asr)),
        (f"sxtb r{d}, r{m}",             lambda M: M.sxtb(d, m)),
        (f"sxth r{d}, r{m}",             lambda M: M.sxth(d, m)),
        (f"uxtb r{d}, r{m}",             lambda M: M.uxtb(d, m)),
        (f"uxth r{d}, r{m}",             lambda M: M.uxth(d, m)),
        (f"rev r{d}, r{m}",              lambda M: M.rev(d, m)),
        (f"rev16 r{d}, r{m}",            lambda M: M.rev16(d, m)),
        (f"revsh r{d}, r{m}",            lambda M: M.revsh(d, m)),
    ]

    # register shifts need the amount in a register, so they come as a pair:
    # load the amount, then shift by it
    sh = shift_src()
    for mn, fn in (("lsls", "lsls_reg"), ("lsrs", "lsrs_reg"),
                   ("asrs", "asrs_reg"), ("rors", "rors_reg")):
        if s == d:
            continue
        cands.append((f"movs r{s}, #{sh & 0xFF}\n  {mn} r{d}, r{s}",
                      (lambda f, ss=s, shv=sh & 0xFF, dd=d:
                       lambda M: (M.movs_imm(ss, shv), getattr(M, f)(dd, ss)))(fn)))

    return rng.choice(cands)


def generate(blocks, length, seed):
    rng = random.Random(seed)
    body, data = [], []

    for b in range(blocks):
        regs = [rng.choice([0, 1, 0x7FFFFFFF, 0x80000000, M32,
                            rng.getrandbits(32)]) for _ in range(8)]
        flags = [rng.randrange(2) for _ in range(4)]
        M = Model(regs, flags)

        body.append(f"\n@ ---- block {b} ----")
        apsr_in = (flags[0] << 31) | (flags[1] << 30) | (flags[2] << 29) | (flags[3] << 28)
        body.append(f"  ldr  r0, =0x{apsr_in:08x}")
        body.append("  msr  apsr_nzcvq, r0")
        for i, v in enumerate(regs):
            body.append(f"  ldr  r{i}, =0x{v:08x}")

        for _ in range(length):
            text, fn = pick(rng)
            body.append(f"  {text}")
            fn(M)

        # push captures every register without needing a spare one to hold a
        # base address, which matters because the block has just used them all
        body.append("  push {r0-r7}")
        body.append("  mrs  r0, apsr")
        body.append("  push {r0}")
        body.append("  mov  r0, sp")
        body.append(f"  ldr  r1, =exp_{b}")
        body.append("  movs r2, #9")
        body.append(f"  movs r3, #{b & 0xFF}")
        body.append("  bl   check_block")
        body.append("  add  sp, #36")
        # a thumb pc-relative load only reaches about 1 kb, so the pool has to
        # be flushed per block and branched over, or the constants for later
        # blocks fall out of range. isatest.S hit the same wall
        body.append("  b    9f")
        body.append("  .ltorg")
        body.append("9:")

        data.append(f"exp_{b}:")
        for w in M.state():
            data.append(f"  .word 0x{w:08x}")

    return body, data


HEAD = """@ GENERATED by tools/isagen.py, do not edit
@
@ randomised armv6-m instruction test. every expected value below came from the
@ reference model in that script, which is an independent implementation of the
@ instruction semantics rather than a description of the rtl. a mismatch means
@ one of the two is wrong and the disagreement is the point.
@
@ results, at the bottom of dtcm, same convention as isatest.S:
@   0x20000000  error count, 0 means pass
@   0x20000004  id of the first failing block, 0 if none
@   0x20000008  0x600dc0de once the test has run to completion
@   0x2000000c  index of the first differing word, 0 apsr, 1..8 r0..r7
@   0x20000010  what the core produced
@   0x20000014  what the model expected

  .syntax unified
  .cpu cortex-m1
  .thumb

  .section .isr_vector, "a"
  .word 0x20002000
  .word reset + 1

  .text
  .align 2

  .thumb_func
reset:
  ldr  r0, =0x20000000
  movs r1, #0
  str  r1, [r0]
  str  r1, [r0, #4]
"""

TAIL = """
done:
  ldr  r3, =0x20000000
  ldr  r0, =0x600dc0de
  str  r0, [r3, #8]
stop:
  b    stop

@ compare r2 words at r0 against r1, counting failures and remembering the
@ first failing block id from r3
  .thumb_func
check_block:
  push {r4, r5, r6, lr}
1:
  ldr  r4, [r0]
  ldr  r5, [r1]
  cmp  r4, r5
  beq  2f
  ldr  r6, =0x20000000
  ldr  r4, [r6]
  adds r4, #1
  str  r4, [r6]
  ldr  r4, [r6, #4]
  cmp  r4, #0
  bne  2f
  adds r3, #1              @ store id+1 so block 0 is distinguishable from none
  str  r3, [r6, #4]
  subs r3, #1
  @ record enough to identify the disagreement without a waveform: which word
  @ of [apsr, r0..r7] differed, and both values
  ldr  r4, [r0]
  str  r4, [r6, #16]       @ actual
  ldr  r4, [r1]
  str  r4, [r6, #20]       @ expected
  movs r4, #9
  subs r4, r4, r2
  str  r4, [r6, #12]       @ word index, 0 is apsr and 1..8 are r0..r7
2:
  adds r0, #4
  adds r1, #4
  subs r2, #1
  bne  1b
  pop  {r4, r5, r6, pc}

@ safe to drop the pool here: the pop above returns, so nothing falls into it.
@ without this the constants for done: and check_block land after the expected
@ data at the end of the file, out of pc-relative reach
  .ltorg

  .align 2
"""


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("-o", "--out", required=True)
    ap.add_argument("--blocks", type=int, default=40)
    ap.add_argument("--len", type=int, default=12)
    ap.add_argument("--seed", type=int, default=1)
    a = ap.parse_args()

    body, data = generate(a.blocks, a.len, a.seed)
    with open(a.out, "w") as f:
        f.write(HEAD)
        f.write("\n".join(body))
        f.write("\n  b    done\n")
        f.write(TAIL)
        f.write("\n".join(data))
        f.write("\n\n  .ltorg\n")
    # the testbench reports how many blocks ran, and it cannot know that from
    # the hex image. emitting it keeps the message honest rather than carrying
    # a constant that drifts the moment --blocks changes
    vh = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                      "..", "tb", "isarand_blocks.vh")
    with open(vh, "w") as f:
        f.write(f"// generated by tools/isagen.py, do not edit\n"
                f"`define ISARAND_BLOCKS {a.blocks}\n")
    print(f"wrote {a.out}: {a.blocks} blocks x {a.len} instructions, seed {a.seed}")


if __name__ == "__main__":
    main()
