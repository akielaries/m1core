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

def load_mcu(path):
    with open(path) as f:
        doc = yaml.safe_load(f)
    if "mcu" not in doc:
        raise ValueError(f"{path}: no top level 'mcu' key")
    return doc["mcu"]


def load_periph_types(mcu):
    types = {}
    for p in mcu.get("peripherals", []):
        t = p["type"]
        if t in types:
            continue
        path = os.path.join(PERIPH_DIR, f"{t}.yaml")
        if not os.path.exists(path):
            raise ValueError(f"unknown peripheral type '{t}', expected {path}")
        with open(path) as f:
            types[t] = yaml.safe_load(f)
    return types


def validate(mcu, types):
    errors = []
    periphs = mcu.get("peripherals", [])

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

    # a base has to sit inside the window its bus actually decodes. without this
    # an apb peripheral placed at 0x4... generates a decode the fabric never
    # selects, and the block is simply dead with no diagnostic anywhere
    for p in periphs:
        bus = p.get("bus")
        if bus in BUS_WINDOW:
            lo, hi = BUS_WINDOW[bus]
            if not lo <= p["base"] < hi:
                errors.append(
                    f"{p['name']}: base {p['base']:#x} is outside the {bus} window "
                    f"[{lo:#x},{hi:#x}), which is what rtl/mcu/ahb_fabric.v decodes")

    # the ahb side of the fabric is still hand written with one named slot for
    # gpio, so unlike apb it cannot absorb another peripheral. generating it is
    # the fix; until then say so rather than emitting rtl that quietly drops it
    ahb = [p for p in periphs if p.get("bus") == "ahb"]
    if len(ahb) > 1:
        errors.append(
            "more than one ahb peripheral (" + ", ".join(p["name"] for p in ahb) +
            "): rtl/mcu/ahb_fabric.v has a single hardwired ahb slot and the "
            "generator would silently drop the rest. put it on apb, or generate "
            "the fabric decode first")
    for p in ahb:
        if p["type"] != "gpio":
            errors.append(
                f"{p['name']}: the one ahb slot in rtl/mcu/ahb_fabric.v is wired "
                f"as gpio, so type '{p['type']}' cannot go there yet")

    # the apb expansion window needs its own ahb to apb bridge, which nothing
    # generates yet. say so rather than emitting a decode with no bridge behind
    # it, which is the exact failure this window already had once
    exp = mcu.get("expansion", {})
    for bus in ("ahb", "apb"):
        cfg = exp.get(bus) or {}
        n, slots = int(cfg.get("enabled", 0)), int(cfg.get("slots", 0))
        if n > slots:
            errors.append(f"expansion.{bus}: enabled {n} exceeds the {slots} "
                          f"slots the address map reserves")
        if bus == "apb" and n:
            errors.append(
                "expansion.apb: not implemented. the window needs its own "
                "ahb_apb_bridge and nothing generates one yet, so enabling it "
                "would decode an address with no bridge behind it")

    if not mcu.get("clock", {}).get("hz"):
        errors.append("mcu.clock.hz is required: software cannot read it back")

    return errors


# ---------------------------------------------------------------------------
# C header
# ---------------------------------------------------------------------------

# what rtl/mcu/ahb_fabric.v decodes on haddr[31:28], see in_gpio and in_apb
BUS_WINDOW = {
    "ahb": (0x40000000, 0x50000000),
    "apb": (0x50000000, 0x60000000),
}

REGION_DEFS = [
    ("ITCM_BASE", 0x00000000),
    ("DTCM_BASE", 0x20000000),
    ("AHB1PERIPH_BASE", 0x40000000),
    ("APB1PERIPH_BASE", 0x50000000),
]


def gen_header(mcu, types, source):
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

    clk = mcu["clock"]
    w("/* the fabric clock. software cannot read this back, there is no PLL to")
    w(f"   interrogate: {clk.get('source', 'see the board top level')} */")
    w(f"#define SYSTEM_CLOCK_HZ  {clk['hz']}u")
    w("")

    w("/* address regions */")
    for name, addr in REGION_DEFS:
        w(f"#define {name:<16} {addr:#010x}u")
    # only the enabled slots get an address define. emitting the window base
    # unconditionally is what made these windows look real when the fabric
    # decoded nothing there and an access returned zero with no error
    for bus in ("apb", "ahb"):
        slots = expansion_slots(mcu, bus)
        if not slots:
            continue
        w(f"/* {bus} expansion windows, decoded by the fabric and brought out")
        w(f"   on the mcu top for user logic */")
        for name, base, size in slots:
            w(f"#define {name.upper() + '_BASE':<16} {base:#010x}u"
              f"   /* {_size_str(size)} */")
        w("")

    periphs = mcu.get("peripherals", [])

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


def gen_apb_rtl(mcu, types, source):
    """the apb subsystem: address decode, peripheral instances, irq vector

    only APB peripherals are generated. AHB ones sit directly in the fabric,
    whose decode is hand written and where there is currently exactly one. this
    is where the system grows, so this is where generation pays.
    """
    apb = [p for p in mcu.get("peripherals", []) if p.get("bus") == "apb"]

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


def gen_memmap(mcu, types, source):
    """the section of the memory map document describing what this build
    actually contains. the surrounding prose and the reference map of planned
    blocks stay hand written: only the facts that can drift are generated"""
    o = []
    w = o.append

    w(f"*Generated from {source}. Everything below the END marker is hand written.*")
    w("")
    w(f"This build is `{mcu.get('name', 'm1core')}`, "
      f"{mcu['cpu']['itcm_kb']} KB ITCM and {mcu['cpu']['dtcm_kb']} KB DTCM, "
      f"clocked at {mcu['clock']['hz'] / 1e6:.0f} MHz.")
    w("")
    w("| Address | Block | Bus | IRQ |")
    w("| --- | --- | --- | --- |")

    mem = [("0x0000_0000", "ITCM", "ahb", None),
           ("0x2000_0000", "DTCM", "ahb", None)]
    for base, name, bus, irq in mem:
        w(f"| {base} | {name} | {bus.upper()} | - |")

    for p in sorted(mcu.get("peripherals", []), key=lambda x: x["base"]):
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


# ---------------------------------------------------------------------------
# ahb fabric
# ---------------------------------------------------------------------------

def _size_str(size):
    if size >= 1 << 20:
        return f"{size >> 20} MB"
    return f"{size >> 10} KB"


def _decode(base, size):
    """the haddr comparison that selects a window of `size` bytes at `base`"""
    lsb = size.bit_length() - 1
    if size != 1 << lsb:
        raise ValueError(f"window size {size:#x} is not a power of two")
    width = 32 - lsb
    return f"(haddr[31:{lsb}] == {width}'h{base >> lsb:X})"


# fixed architectural windows. itcm and dtcm own a whole 256 MB nibble each so
# a linker script can put anything anywhere inside them, and the ppb is the
# 1 MB the armv6-m architecture places the scs and rom table in
NIBBLE = 0x10000000
FIXED_SLAVES = [
    ("itcm", 0x00000000, NIBBLE),
    ("dtcm", 0x20000000, NIBBLE),
]


def ahb_slaves(mcu, types):
    """every slave on the fabric, in decode order

    ahb peripherals are decoded to their own size rather than to the whole 0x4
    nibble, which is what lets there be more than one of them
    """
    slaves = list(FIXED_SLAVES)

    for p in mcu.get("peripherals", []):
        if p.get("bus") == "ahb":
            slaves.append((p["name"], p["base"], types[p["type"]].get("size", 0x1000)))

    slaves.append(("apb", BUS_WINDOW["apb"][0], NIBBLE))

    for name, base, size in expansion_slots(mcu, "ahb"):
        slaves.append((name, base, size))

    slaves.append(("ppb", 0xE0000000, 0x100000))
    return slaves


def expansion_slots(mcu, bus):
    """the user attachment windows, gowin calls these ahb/apb master 1..n

    `slots` is how many the address map reserves, `enabled` how many are
    actually brought out as ports. generating six unused ahb port bundles onto
    the top level costs pins in the netlist and noise in the file, so the
    default is none and you turn on what you attach
    """
    exp = mcu.get("expansion", {}).get(bus)
    if not exp:
        return []
    n = int(exp.get("enabled", 0))
    size = int(exp["size_kb"]) * 1024
    base = int(exp["base"])
    return [(f"{bus}exp{i}", base + i * size, size) for i in range(n)]


def gen_ahb_rtl(mcu, types, source):
    o = []
    w = o.append

    slaves = ahb_slaves(mcu, types)
    sel_w = max(1, (len(slaves) + 1 - 1).bit_length())

    w("`default_nettype none")
    w("")
    w("// ahb-lite address decode and read data mux")
    w("//")
    w(f"// generated by tools/m1core_gen.py from {source}, do not edit")
    w("//")
    w("// the slave select must be registered as well as decoded, because hrdata")
    w("// comes back one cycle after the address phase that chose the slave")
    w("//")
    w("// memory map:")
    for name, base, size in slaves:
        w(f"//   0x{base:08X}  {name}, {_size_str(size)}")
    w("")
    w("module ahb_fabric (")
    w("  input  wire        clk,")
    w("  input  wire        rst_n,")
    w("")
    w("  // from the master")
    w("  input  wire [31:0] haddr,")
    w("  input  wire [1:0]  htrans,")
    w("  output reg  [31:0] hrdata,")
    w("  output reg         hready,")
    w("  output wire        hresp,")
    w("")
    w("  // slave selects")
    for name, _, _ in slaves:
        w(f"  output wire        hsel_{name},")
    for name, _, _ in slaves:
        w(f"  input  wire [31:0] hrdata_{name},")
    w("")
    w("  // per slave ready. zero wait state slaves tie these high; a bridge to a")
    w("  // slower bus drives its own low while a transfer is in flight")
    for i, (name, _, _) in enumerate(slaves):
        comma = "" if i == len(slaves) - 1 else ","
        w(f"  input  wire        hreadyout_{name}{comma}")
    w(");")
    w("")
    w(f"  localparam [{sel_w - 1}:0] SEL_NONE = {sel_w}'d0;")
    for i, (name, _, _) in enumerate(slaves):
        w(f"  localparam [{sel_w - 1}:0] SEL_{name.upper()} = {sel_w}'d{i + 1};")
    w("")
    w("  assign hresp = 1'b0;")
    w("")
    for name, base, size in slaves:
        w(f"  wire in_{name} = {_decode(base, size)};")
    w("")
    for name, _, _ in slaves:
        w(f"  assign hsel_{name} = in_{name};")
    w("")
    w(f"  reg [{sel_w - 1}:0] sel_q;")
    w("")
    w("  always @(posedge clk or negedge rst_n) begin")
    w("    if (!rst_n) begin")
    w("      sel_q <= SEL_NONE;")
    w("    end else if (htrans[1]) begin")
    for i, (name, _, _) in enumerate(slaves):
        kw = "if" if i == 0 else "end else if"
        w(f"      {kw} (in_{name}) begin")
        w(f"        sel_q <= SEL_{name.upper()};")
    w("      end else begin")
    w("        sel_q <= SEL_NONE;")
    w("      end")
    w("    end")
    w("  end")
    w("")
    w("  // hready qualifies both phases and comes from whichever slave owns the")
    w("  // current data phase, which is the one selected during the address phase")
    w("  always @(*) begin")
    w("    case (sel_q)")
    for name, _, _ in slaves:
        w(f"      SEL_{name.upper()}: hready = hreadyout_{name};")
    w("      default:  hready = 1'b1;")
    w("    endcase")
    w("  end")
    w("")
    w("  always @(*) begin")
    w("    case (sel_q)")
    for name, _, _ in slaves:
        w(f"      SEL_{name.upper()}: hrdata = hrdata_{name};")
    w("      // an unmapped read returns zero rather than an error, so a stray probe")
    w("      // access cannot set stickyerr and lock out every later transfer")
    w("      default:  hrdata = 32'd0;")
    w("    endcase")
    w("  end")
    w("")
    w("endmodule")
    w("")
    w("`default_nettype wire")
    return "\n".join(o) + "\n"


# one ahb-lite slave interface, brought out to the top so user logic can be
# attached in an expansion window. hready is the global one: an ahb-lite slave
# needs it to know when the address phase it is seeing is real
EXP_AHB_PORTS = [
    ("output wire       ", "hsel"),
    ("output wire [31:0]", "haddr"),
    ("output wire       ", "hwrite"),
    ("output wire [1:0] ", "htrans"),
    ("output wire [2:0] ", "hsize"),
    ("output wire [31:0]", "hwdata"),
    ("output wire       ", "hready"),
    ("input  wire [31:0]", "hrdata"),
    ("input  wire       ", "hreadyout"),
]


def gen_mcu_regions(mcu, types, source):
    """the parts of m1core_mcu.v that depend on the mcu description: external
    pin ports, the apb instance pin connections, and the whole bus fabric,
    whose port list changes with every slave added or removed"""
    apb = [p for p in mcu.get("peripherals", []) if p.get("bus") == "apb"]

    ports = []
    conns = []
    for p in apb:
        for pin in types[p["type"]].get("pins", []):
            d = "input  wire" if pin["dir"] == "input" else "output wire"
            sig = f"{p['name']}_{pin['name']}"
            ports.append(f"  , {d}        {sig}")
            conns.append(f"    , .{sig:<10} ({sig})")

    # expansion windows come out as a full slave interface each
    exp = [n for n, _, _ in expansion_slots(mcu, "ahb")]
    for name in exp:
        ports.append(f"  // {name}: ahb-lite expansion window for user logic")
        for d, sig in EXP_AHB_PORTS:
            ports.append(f"  , {d} {name}_{sig}")

    return {
        "periph-ports": ("\n".join(ports) + "\n") if ports else "",
        "apb-pins": ("\n".join(conns) + "\n") if conns else "",
        "fabric": gen_fabric_inst(mcu, types),
    }


def gen_fabric_inst(mcu, types):
    """the fabric wire declarations and instantiation

    generated because the fabric's port list is one group per slave, so it
    changes whenever a peripheral or an expansion window is added
    """
    slaves = ahb_slaves(mcu, types)
    exp = {n for n, _, _ in expansion_slots(mcu, "ahb")}
    o = []
    w = o.append

    names = [n for n, _, _ in slaves]
    internal = [n for n in names if n not in exp]

    w("  wire        " + ", ".join(f"hsel_{n}" for n in internal) + ";")
    w("  wire [31:0] " + ", ".join(f"hrdata_{n}" for n in internal) + ";")
    w("  wire        hreadyout_apb;")
    w("")
    for name in sorted(exp):
        # the expansion slave sees the same address and data phase the internal
        # slaves do; only its select is gated by the window decode
        w(f"  assign {name}_haddr  = haddr;")
        w(f"  assign {name}_hwrite = hwrite;")
        w(f"  assign {name}_htrans = htrans;")
        w(f"  assign {name}_hsize  = hsize;")
        w(f"  assign {name}_hwdata = hwdata;")
        w(f"  assign {name}_hready = hready;")
        w("")
    w("  ahb_fabric u_fabric (")
    w("    .clk         (clk),")
    w("    .rst_n       (rst_n_i),")
    w("    .haddr       (haddr),")
    w("    .htrans      (htrans),")
    w("    .hrdata      (hrdata),")
    w("    .hready      (hready),")
    w("    .hresp       (hresp),")
    for n in names:
        src = f"{n}_hsel" if n in exp else f"hsel_{n}"
        w(f"    .hsel_{n:<9} ({src}),")
    for n in names:
        src = f"{n}_hrdata" if n in exp else f"hrdata_{n}"
        w(f"    .hrdata_{n:<7} ({src}),")
    w("    // internal slaves are all zero wait state; the apb bridge and any")
    w("    // expansion window drive a real hreadyout")
    for i, n in enumerate(names):
        if n in exp:
            src = f"{n}_hreadyout"
        elif n == "apb":
            src = "hreadyout_apb"
        else:
            src = "1'b1"
        comma = "" if i == len(names) - 1 else ","
        w(f"    .hreadyout_{n:<4} ({src}){comma}")
    w("  );")
    return "\n".join(o) + "\n"


def splice_mcu(path, mcu, types, source):
    text = open(path).read()
    for name, block in gen_mcu_regions(mcu, types, source).items():
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
    ap.add_argument("mcu", metavar="mcu.yaml",
                    help="mcu description, e.g. boards/gw5a25/mcu.yaml")
    ap.add_argument("--header")
    ap.add_argument("--memmap")
    ap.add_argument("--apb-rtl")
    ap.add_argument("--mcu-rtl")
    ap.add_argument("--ahb-rtl")
    ap.add_argument("--check", action="store_true",
                    help="report whether the file on disk is up to date, write nothing")
    args = ap.parse_args()

    mcu = load_mcu(args.mcu)
    types = load_periph_types(mcu)

    errors = validate(mcu, types)
    if errors:
        for e in errors:
            print(f"FAIL {args.mcu}: {e}", file=sys.stderr)
        return 1

    # relative to the repo root, not the invoking directory, or the provenance
    # comment changes with where the tool was run from and --check reports a
    # spurious difference
    src = os.path.relpath(os.path.abspath(args.mcu), REPO)

    outputs = []
    if args.header:
        outputs.append((args.header, gen_header(mcu, types, src)))
    if args.memmap:
        outputs.append((args.memmap,
                        splice_memmap(args.memmap, gen_memmap(mcu, types, src))))
    if args.apb_rtl:
        outputs.append((args.apb_rtl, gen_apb_rtl(mcu, types, src)))
    if args.ahb_rtl:
        outputs.append((args.ahb_rtl, gen_ahb_rtl(mcu, types, src)))
    if args.mcu_rtl:
        outputs.append((args.mcu_rtl, splice_mcu(args.mcu_rtl, mcu, types, src)))
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
