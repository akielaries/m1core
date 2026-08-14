# ID contract

Every value here was derived by reading the Black Magic Probe source in
`pub/blackmagic`, not from memory. File and line references are to that tree.

The goal: satisfy *stock* BMP so the Gowin-specific hacks in our branch become
unnecessary. What Gowin's M1 gets wrong, we get right.

## What our BMP branch currently patches around

`git diff 82a05810..HEAD` in pub/blackmagic shows four changes. Two are
workarounds for Gowin defects, two are genuinely missing upstream support.

| Patch | Reason | Needed by our clone? |
| --- | --- | --- |
| `GOWIN_M1_DPIDR` bypass of the CIDR preamble check (adi.c:819) | Gowin emits a CIDR that does not match `0xb105_x00d` | No, we emit legal CIDRs |
| Force `cortexm_probe` when PIDR==0 at 0xE000E000 (adi.c:832) | Gowin's SCS has no valid PIDR | No, we emit a legal SCS PIDR |
| `CORTEX_M1 = 0xc210` + case in cortex.c | M1 genuinely absent upstream | Yes, keep. Upstreamable |
| `part_id == 0x470` -> "Generic Cortex-M1" (cortexm.c:468) | M1 ROM part number absent upstream | Yes, keep. Upstreamable |

So the endgame is: delete the two workarounds, keep the two additions, and the
branch turns into a clean two-hunk patch worth sending upstream.

## Discovery path BMP actually walks

1. `adi_ap_component_probe` reads CIDR0-3, requires `(cidr & ~0xf000) == 0xb105000d` (adiv5_internal.h:163)
2. Reads PIDR0-3 @ 0xFE0.. and PIDR4-7 @ 0xFD0.. ; **PIDR==0 aborts the component** (adi.c:832)
3. Class in CIDR bits [15:12]. Class 0x1 = ROM table -> recurse. Otherwise -> LUT lookup
4. Designer from PIDR must be `0x43b` (ARM) or ARM China, else "Non-ARM component ignored" (adi.c:857)
5. `adi_lookup_component` matches on **part_number + dev_type + arch_id** exactly (adi.c:315)
6. A matched entry with `arch == aa_cortexm` calls `cortexm_probe` (adi.c:884)

Two things worth knowing, both confirmed in source:

- The component class is only sanity-checked with a `DEBUG_WARN`, never fatal (adi.c:329).
- `dev_type` and `arch_id` are only read when class == 0x9 (`cidc_dc`). For a
  class-0xE component both are 0, which is what the SCS LUT entries expect.

## CIDR encoding

BMP packs byte lanes from 0xFF0/0xFF4/0xFF8/0xFFC into `0xB105_X00D`, X = class.

| Component | Class | CIDR0 | CIDR1 | CIDR2 | CIDR3 | Assembled |
| --- | --- | --- | --- | --- | --- | --- |
| ROM table | 0x1 | 0x0D | 0x10 | 0x05 | 0xB1 | 0xB105100D |
| SCS       | 0xE | 0x0D | 0xE0 | 0x05 | 0xB1 | 0xB105E00D |

Class 0xE is `cidc_gipc` (adiv5_internal.h:268), which is what the Cortex-M0/M3/M4
SCS entries in the LUT declare.

## PIDR encoding

Field layout per adiv5_internal.h:167-176, verified against the extraction code
at adi.c:271-278.

```
PIDR0[7:0] = PART[7:0]
PIDR1[3:0] = PART[11:8]      PIDR1[7:4] = DES[3:0]
PIDR2[2:0] = DES[6:4]        PIDR2[3]   = JEDEC (must be 1)   PIDR2[7:4] = REVISION
PIDR3      = 0
PIDR4[3:0] = DES_2 (JEP106 continuation)   PIDR4[7:4] = SIZE (must be 0)
PIDR5..7   = 0
```

ARM's JEP106 code is identity 0x3B, continuation 0x4, giving designer 0x43b.
That fixes DES[3:0]=0xB, DES[6:4]=0x3, DES_2=0x4, so PIDR1[7:4]=0xB,
PIDR2=0x0B, PIDR4=0x04 for every component we emit.

**SIZE must be zero.** A nonzero PIDR4[7:4] makes BMP print "Fault reading ROM
table" and abandon the walk (adi.c:847).

| Component | Part | PIDR0 | PIDR1 | PIDR2 | PIDR3 | PIDR4 |
| --- | --- | --- | --- | --- | --- | --- |
| ROM table | 0x470 | 0x70 | 0xB4 | 0x0B | 0x00 | 0x04 |
| SCS       | 0x008 | 0x08 | 0xB0 | 0x0B | 0x00 | 0x04 |
| DWT       | 0x00A | 0x0A | 0xB0 | 0x0B | 0x00 | 0x04 |
| BPU       | 0x00B | 0x0B | 0xB0 | 0x0B | 0x00 | 0x04 |

Part 0x008 is the Cortex-M0 SCS. We deliberately reuse it: it is the ARMv6-M SCS
part number, and critically it is already in BMP's LUT as `aa_cortexm` (adi.c:93),
so **stock** BMP dispatches `cortexm_probe` with no patch. There is no M1 SCS
entry upstream, so inventing a distinct part number would require patching BMP.

Part 0x470 for the ROM table is the architecturally correct M1 value and is what
our `cortexm.c` patch already keys on. The ROM table part number is never looked
up in the LUT (class 0x1 short-circuits at adi.c:845), so it needs no LUT entry
for the walk to succeed.

## ROM table @ 0xE00FF000

Entry format (adiv5.h:193): bit0 = present, bit1 = 32-bit format, [31:12] = signed
offset from the ROM table base.

| Offset | Value | Meaning |
| --- | --- | --- |
| 0x000 | 0xFFF0F003 | SCS @ 0xE000E000 |
| 0x004 | 0xFFF02003 | DWT @ 0xE0001000 |
| 0x008 | 0xFFF03003 | BPU @ 0xE0002000 |
| 0x00C | 0x00000000 | end of table |
| 0xFCC | 0x00000001 | MEMTYPE, SYSMEM present |

A zero entry terminates the walk (adi.c:889). The loop bound is 960 entries.

## CPUID @ 0xE000ED00

```
[31:24] implementer  0x41 (ARM)
[23:20] variant      0x0
[19:16] architecture 0xC  (ARMv6-M)
[15:4]  part number  0xC21 (Cortex-M1)
[3:0]   revision     0x0
```

= **0x410CC210**

BMP masks with 0xFFF0 and compares against `CORTEX_M1 0xc210` (cortex.h:46), which
confirms the constant in our patch is right.

## DPIDR

```
[31:28] revision  0x0
[27:20] partno    0xC1
[19:17] res0      0
[16]    min       0
[15:12] version   0x1 (DPv1)
[11:1]  designer  0x23B (ARM)
[0]     RAO       1
```

= **0x0C101477**

Deliberately *not* Gowin's 0x2BA01477. If we matched it, our patched BMP would
take the `is_gowin_m1` path and skip the CIDR preamble check, hiding exactly the
bugs this milestone exists to catch. Using a distinct DPIDR forces the strict path.

DPv1 is chosen over DPv2 so we do not have to implement dormant state or TARGETSEL.

## AP IDR

`0x24770011` - ARM designer, class 0x8 (MEM-AP), type 0x1 (AMBA AHB3), variant 1,
revision 2. A widely deployed AHB-AP value.
