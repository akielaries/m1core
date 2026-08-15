#!/usr/bin/env python3
"""generate m1core artefacts from an MCU description

Reads a board's mcu.yaml (composition: which peripherals, where, which IRQ) plus
the per-type register layouts in tools/peripherals/ (what is inside each block),
and emits the C device header.

The split is deliberate and described in docs/mcu-config.md. This tool never
needs to know what bits a UART's CTRL register has; it only needs to know a UART
exists at an address.

Usage:
    m1core_gen.py <mcu.yaml> --header <out.h>
    m1core_gen.py <mcu.yaml> --header <out.h> --check   # diff, do not write
"""

import argparse
import difflib
import os
import sys

try:
    import yaml
except ImportError:
    sys.exit("m1core_gen needs PyYAML: pip install pyyaml")

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HERE)
PERIPH_DIR = os.path.join(HERE, "peripherals")


# ---------------------------------------------------------------------------
# loading and validation
#
# every rule lives here rather than in a GUI, so the CLI enforces it too and it
# can be tested without clicking anything
# ---------------------------------------------------------------------------

def load_soc(path):
    with open(path) as f:
        doc = yaml.safe_load(f)
    if "mcu" not in doc:
        raise ValueError(f"{path}: no top level 'mcu' key")
    return doc["mcu"]


def load_periph_types(soc):
    types = {}
    for p in soc.get("peripherals", []):
        t = p["type"]
        if t in types:
            continue
        path = os.path.join(PERIPH_DIR, f"{t}.yaml")
        if not os.path.exists(path):
            raise ValueError(f"unknown peripheral type '{t}', expected {path}")
        with open(path) as f:
            types[t] = yaml.safe_load(f)
    return types


def validate(soc, types):
    errors = []
    periphs = soc.get("peripherals", [])

    seen_names = set()
    seen_irqs = {}
    spans = []

    for p in periphs:
        name = p["name"]
        if name in seen_names:
            errors.append(f"duplicate peripheral name '{name}'")
        seen_names.add(name)

        if p.get("bus") not in ("ahb", "apb"):
            errors.append(f"{name}: bus must be ahb or apb, got {p.get('bus')!r}")

        base = p["base"]
        size = types[p["type"]].get("size", 0x1000)
        if base % size:
            errors.append(f"{name}: base {base:#x} is not aligned to its {size:#x} size")
        spans.append((base, base + size, name))

        irq = p.get("irq")
        if irq is not None:
            if irq in seen_irqs:
                errors.append(f"{name}: irq {irq} already used by {seen_irqs[irq]}")
            seen_irqs[irq] = name
            if not 0 <= irq <= 31:
                errors.append(f"{name}: irq {irq} outside 0..31")

    # overlapping address windows are the failure that is hardest to spot by eye
    spans.sort()
    for (a_lo, a_hi, a_name), (b_lo, b_hi, b_name) in zip(spans, spans[1:]):
        if b_lo < a_hi:
            errors.append(
                f"{a_name} [{a_lo:#x},{a_hi:#x}) overlaps {b_name} [{b_lo:#x},{b_hi:#x})")

    if not soc.get("clock", {}).get("hz"):
        errors.append("mcu.clock.hz is required: software cannot read it back")

    return errors


# ---------------------------------------------------------------------------
# C header
# ---------------------------------------------------------------------------

REGION_DEFS = [
    ("ITCM_BASE", 0x00000000),
    ("DTCM_BASE", 0x20000000),
    ("AHB1PERIPH_BASE", 0x40000000),
    ("APB1PERIPH_BASE", 0x50000000),
]


def gen_header(soc, types, source):
    o = []
    w = o.append

    w("/*")
    w(" * m1core device header")
    w(" *")
    w(f" * GENERATED from {source} by tools/m1core_gen.py. Do not edit.")
    w(" * Change the SoC description and regenerate, so the RTL, this header and")
    w(" * docs/memory-map.md cannot drift apart.")
    w(" *")
    w(" * Register layouts come from tools/peripherals/<type>.yaml.")
    w(" */")
    w("#ifndef M1CORE_H")
    w("#define M1CORE_H")
    w("")
    w("#include <stdint.h>")
    w("")

    clk = soc["clock"]
    w("/* the fabric clock. software cannot read this back, there is no PLL to")
    w(f"   interrogate: {clk.get('source', 'see the board top level')} */")
    w(f"#define SYSTEM_CLOCK_HZ  {clk['hz']}u")
    w("")

    w("/* address regions */")
    for name, addr in REGION_DEFS:
        w(f"#define {name:<16} {addr:#010x}u")
    exp = soc.get("expansion", {})
    if "apb" in exp:
        w(f"#define {'APB_EXPAND_BASE':<16} {exp['apb']['base']:#010x}u")
    if "ahb" in exp:
        w(f"#define {'AHB_EXPAND_BASE':<16} {exp['ahb']['base']:#010x}u")
    w("")

    periphs = soc.get("peripherals", [])

    w("/* peripheral instances */")
    for p in periphs:
        w(f"#define {p['name'].upper() + '_BASE':<16} {p['base']:#010x}u")
    w("")

    irq_periphs = [p for p in periphs if p.get("irq") is not None]
    if irq_periphs:
        w("/* interrupt numbers. numbering follows gowin's empu m1 so m1kern's")
        w("   target layer ports across unchanged */")
        w("typedef enum {")
        rows = sorted(irq_periphs, key=lambda p: p["irq"])
        for i, p in enumerate(rows):
            comma = "," if i < len(rows) - 1 else ""
            w(f"  {p['name'].upper() + '_IRQn':<12} = {p['irq']}{comma}")
        w("} IRQn_Type;")
        w("")

    emitted = set()
    for p in periphs:
        t = types[p["type"]]
        if t["struct"] in emitted:
            continue
        emitted.add(t["struct"])
        w(f"/* {t.get('doc', p['type'])} */")
        w("typedef struct {")
        width = max(len(r["name"]) for r in t["registers"])
        for r in t["registers"]:
            doc = f"  /* {r['offset']:#04x} {r['doc']} */" if r.get("doc") else ""
            w(f"  volatile uint32_t {r['name'] + ';':<{width + 1}}{doc}")
        w(f"}} {t['struct']};")
        w("")

    w("/* instance pointers */")
    for p in periphs:
        t = types[p["type"]]
        w(f"#define {p['name'].upper():<6} (({t['struct']} *){p['name'].upper()}_BASE)")
    w("")

    bit_lines = []
    for p in periphs:
        t = types[p["type"]]
        if t["struct"] in emitted and t.get("bits"):
            for reg, bits in t["bits"].items():
                for bit, pos in bits.items():
                    prefix = f"{p['type'].upper()}_{reg}_{bit}"
                    line = f"#define {prefix:<24} (1u << {pos})"
                    if line not in bit_lines:
                        bit_lines.append(line)
    if bit_lines:
        w("/* register bits */")
        o.extend(bit_lines)
        w("")

    w("#endif /* M1CORE_H */")
    return "\n".join(o) + "\n"


def gen_apb_rtl(soc, types, source):
    """the apb subsystem: address decode, peripheral instances, irq vector

    only APB peripherals are generated. AHB ones sit directly in the fabric,
    whose decode is hand written and where there is currently exactly one. this
    is where the system grows, so this is where generation pays.
    """
    apb = [p for p in soc.get("peripherals", []) if p.get("bus") == "apb"]

    o = []
    w = o.append
    w("`default_nettype none")
    w("")
    w("// m1core apb subsystem")
    w("//")
    w(f"// GENERATED from {source} by tools/m1core_gen.py. Do not edit.")
    w("// Add a peripheral to the MCU description and regenerate.")
    w("//")
    w("// One AHB slot feeds this no matter how many peripherals hang off it,")
    w("// which is why the fabric decode does not grow as the system does.")
    w("")
    w("module m1core_apb (")
    w("  input  wire        clk,")
    w("  input  wire        rst_n,")
    w("")
    w("  // apb slave side, from ahb_apb_bridge")
    w("  input  wire        psel,")
    w("  input  wire        penable,")
    w("  input  wire        pwrite,")
    w("  input  wire [31:0] paddr,")
    w("  input  wire [31:0] pwdata,")
    w("  output reg  [31:0] prdata,")
    w("  output reg         pready,")
    w("")
    w("  // interrupt vector, one bit per irq number")
    w("  output wire [31:0] irq,")

    for p in apb:
        t = types[p["type"]]
        pins = t.get("pins", [])
        if pins:
            w("")
            w(f"  // {p['name']}")
        for i, pin in enumerate(pins):
            last = (p is apb[-1]) and (i == len(pins) - 1)
            comma = "" if last else ","
            d = "input  wire" if pin["dir"] == "input" else "output wire"
            w(f"  {d}        {p['name']}_{pin['name']}{comma}")
    w(");")
    w("")

    if not apb:
        w("  assign irq = 32'd0;")
        w("  always @(*) begin")
        w("    prdata = 32'd0;")
        w("    pready = 1'b1;")
        w("  end")
        w("")
        w("endmodule")
        w("")
        w("`default_nettype wire")
        return "\n".join(o) + "\n"

    w("  // address decode. the apb window base is stripped by the fabric, so the")
    w("  // comparison is on the offset within it")
    for p in apb:
        sel_bits = (p["base"] >> 12) & 0xFFFF
        w(f"  wire sel_{p['name']} = (paddr[27:12] == 16'h{sel_bits:04x});")
    w("")

    for p in apb:
        w(f"  wire [31:0] prdata_{p['name']};")
        w(f"  wire        pready_{p['name']};")
    w("")

    irq_periphs = [p for p in apb
                   if p.get("irq") is not None and types[p["type"]].get("irq_port")]
    for p in irq_periphs:
        w(f"  wire irq_{p['name']};")
    if irq_periphs:
        w("")

    w("  // read data and ready mux")
    w("  always @(*) begin")
    w("    prdata = 32'd0;")
    w("    pready = 1'b1;")
    for p in apb:
        w(f"    if (sel_{p['name']}) begin")
        w(f"      prdata = prdata_{p['name']};")
        w(f"      pready = pready_{p['name']};")
        w("    end")
    w("  end")
    w("")

    w("  // interrupt vector. unused lines tie low")
    # collapse runs of unused lines into a single sized zero, otherwise a 32 bit
    # vector with one source in it is an unreadable wall of 1'b0
    terms = []
    run = 0
    for i in range(31, -1, -1):
        match = next((p for p in irq_periphs if p["irq"] == i), None)
        if match:
            if run:
                terms.append(f"{run}'d0")
                run = 0
            terms.append(f"irq_{match['name']}")
        else:
            run += 1
    if run:
        terms.append(f"{run}'d0")
    w("  assign irq = {" + ", ".join(terms) + "};")
    w("")

    for p in apb:
        t = types[p["type"]]
        w(f"  {t['module']} u_{p['name']} (")
        w("    .clk     (clk),")
        w("    .rst_n   (rst_n),")
        w(f"    .psel    (psel && sel_{p['name']}),")
        w("    .penable (penable),")
        w("    .pwrite  (pwrite),")
        w("    .paddr   (paddr),")
        w("    .pwdata  (pwdata),")
        w(f"    .prdata  (prdata_{p['name']}),")
        w(f"    .pready  (pready_{p['name']}),")
        conns = []
        for pin in t.get("pins", []):
            conns.append(f"    .{pin['name']:<7} ({p['name']}_{pin['name']})")
        if t.get("irq_port"):
            target = f"irq_{p['name']}" if p in irq_periphs else ""
            conns.append(f"    .{t['irq_port']:<7} ({target})")
        w(",\n".join(conns))
        w("  );")
        w("")

    w("endmodule")
    w("")
    w("`default_nettype wire")
    return "\n".join(o) + "\n"


BEGIN_MARK = "<!-- BEGIN GENERATED, do not edit: tools/m1core_gen.py --memmap -->"
END_MARK = "<!-- END GENERATED -->"


def gen_memmap(soc, types, source):
    """the section of the memory map document describing what this build
    actually contains. the surrounding prose and the reference map of planned
    blocks stay hand written: only the facts that can drift are generated"""
    o = []
    w = o.append

    w(f"*Generated from {source}. Everything below the END marker is hand written.*")
    w("")
    w(f"This build is `{soc.get('name', 'm1core')}`, "
      f"{soc['cpu']['itcm_kb']} KB ITCM and {soc['cpu']['dtcm_kb']} KB DTCM, "
      f"clocked at {soc['clock']['hz'] / 1e6:.0f} MHz.")
    w("")
    w("| Address | Block | Bus | IRQ |")
    w("| --- | --- | --- | --- |")

    mem = [("0x0000_0000", "ITCM", "ahb", None),
           ("0x2000_0000", "DTCM", "ahb", None)]
    for base, name, bus, irq in mem:
        w(f"| {base} | {name} | {bus.upper()} | - |")

    for p in sorted(soc.get("peripherals", []), key=lambda x: x["base"]):
        base = f"0x{p['base'] >> 16:04X}_{p['base'] & 0xFFFF:04X}"
        irq = p["irq"] if p.get("irq") is not None else "-"
        w(f"| {base} | {p['name'].upper()} | {p['bus'].upper()} | {irq} |")

    w("| 0xE000_0000 | PPB | AHB | - |")
    w("")
    return "\n".join(o)


def splice_region(text, name, block):
    """replace one named region between markers, leaving everything else alone

    used for files that are mostly hand written with a few generated parts. the
    alternative, generating the whole file, would mean moving four hundred lines
    of perfectly good verilog into python string literals
    """
    begin = f"BEGIN GENERATED {name}"
    end = f"END GENERATED {name}"
    if begin not in text or end not in text:
        raise ValueError(f"missing markers for region '{name}'")
    head, rest = text.split(begin, 1)
    _, tail = rest.split(end, 1)
    # reuse the indentation of the begin marker so the end marker lines up,
    # whatever nesting the region sits at
    indent = head[head.rfind("\n") + 1:]
    return head + begin + "\n" + block + indent + end + tail


def gen_mcu_regions(soc, types, source):
    """the two parts of m1core_mcu.v that depend on the peripheral list:
    the external pin ports, and the pin connections on the apb instance"""
    apb = [p for p in soc.get("peripherals", []) if p.get("bus") == "apb"]

    ports = []
    conns = []
    for p in apb:
        for pin in types[p["type"]].get("pins", []):
            d = "input  wire" if pin["dir"] == "input" else "output wire"
            sig = f"{p['name']}_{pin['name']}"
            ports.append(f"  , {d}        {sig}")
            conns.append(f"    , .{sig:<10} ({sig})")

    return {
        "periph-ports": ("\n".join(ports) + "\n") if ports else "",
        "apb-pins": ("\n".join(conns) + "\n") if conns else "",
    }


def splice_mcu(path, soc, types, source):
    text = open(path).read()
    for name, block in gen_mcu_regions(soc, types, source).items():
        text = splice_region(text, name, block)
    return text


def splice_memmap(path, block):
    text = open(path).read()
    if BEGIN_MARK not in text or END_MARK not in text:
        raise ValueError(f"{path}: missing generated markers")
    head = text.split(BEGIN_MARK)[0]
    tail = text.split(END_MARK, 1)[1]
    return head + BEGIN_MARK + "\n" + block + END_MARK + tail


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("soc")
    ap.add_argument("--header")
    ap.add_argument("--memmap")
    ap.add_argument("--apb-rtl")
    ap.add_argument("--mcu-rtl")
    ap.add_argument("--check", action="store_true",
                    help="report whether the file on disk is up to date, write nothing")
    args = ap.parse_args()

    soc = load_soc(args.soc)
    types = load_periph_types(soc)

    errors = validate(soc, types)
    if errors:
        for e in errors:
            print(f"FAIL {args.soc}: {e}", file=sys.stderr)
        return 1

    # relative to the repo root, not the invoking directory, or the provenance
    # comment changes with where the tool was run from and --check reports a
    # spurious difference
    src = os.path.relpath(os.path.abspath(args.soc), REPO)

    outputs = []
    if args.header:
        outputs.append((args.header, gen_header(soc, types, src)))
    if args.memmap:
        outputs.append((args.memmap,
                        splice_memmap(args.memmap, gen_memmap(soc, types, src))))
    if args.apb_rtl:
        outputs.append((args.apb_rtl, gen_apb_rtl(soc, types, src)))
    if args.mcu_rtl:
        outputs.append((args.mcu_rtl, splice_mcu(args.mcu_rtl, soc, types, src)))
    if not outputs:
        print("nothing to do: pass --header, --memmap and/or --apb-rtl", file=sys.stderr)
        return 1

    failed = False
    for path, text in outputs:
        rel = os.path.relpath(os.path.abspath(path), REPO)
        if args.check:
            if not os.path.exists(path):
                print(f"FAIL {rel} does not exist")
                failed = True
                continue
            if open(path).read() != text:
                print(f"FAIL {rel} is out of date, regenerate it")
                diff = difflib.unified_diff(open(path).read().splitlines(),
                                            text.splitlines(),
                                            "on disk", "generated", lineterm="", n=1)
                for line in list(diff)[:30]:
                    print("  " + line)
                failed = True
            else:
                print(f"ok   {rel} matches the mcu description")
        else:
            with open(path, "w") as f:
                f.write(text)
            print(f"wrote {rel}")

    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
