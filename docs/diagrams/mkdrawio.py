#!/usr/bin/env python3
"""generate docs/diagrams/m1core-soc.drawio from the facts in the rtl"""
import html, os

OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                   "m1core-soc.drawio")

# palette, following the signalmesh diagrams
CORE  = "fillColor=#E3F2FD;strokeColor=#1565C0;"
FAB   = "fillColor=#E0F2F1;strokeColor=#00695C;"
MEM   = "fillColor=#FFF3E0;strokeColor=#EF6C00;"
PERIF = "fillColor=#F3E5F5;strokeColor=#6A1B9A;"
DBG   = "fillColor=#E8F5E9;strokeColor=#2E7D32;"
EXT   = "fillColor=#ECEFF1;strokeColor=#455A64;"
OFF   = "fillColor=#FAFAFA;strokeColor=#BDBDBD;fontColor=#9E9E9E;dashed=1;"

BOX = ("rounded=1;whiteSpace=wrap;html=1;arcSize=8;fontSize=11;"
       "fontFamily=Helvetica;verticalAlign=middle;")
TITLE = "text;html=1;fontSize=15;fontStyle=1;fontFamily=Helvetica;align=left;"
NOTE = ("text;html=1;fontSize=10;fontFamily=Helvetica;align=left;"
        "verticalAlign=top;fontColor=#546E7A;")

EDGE = ("edgeStyle=orthogonalEdgeStyle;rounded=0;html=1;fontSize=9;"
        "fontFamily=Helvetica;strokeColor=#37474F;")
IRQ = ("edgeStyle=orthogonalEdgeStyle;rounded=0;html=1;fontSize=9;"
       "fontFamily=Helvetica;strokeColor=#C62828;dashed=1;endArrow=block;"
       "endSize=6;")

class Sheet:
    def __init__(self, name):
        self.name, self.cells, self.n = name, [], 0

    def _id(self, want=None):
        if want:
            return want
        self.n += 1
        return "n%d" % self.n

    def box(self, x, y, w, h, label, style, cid=None):
        cid = self._id(cid)
        self.cells.append(
            '<mxCell id="%s" value="%s" style="%s" vertex="1" parent="1">'
            '<mxGeometry x="%d" y="%d" width="%d" height="%d" as="geometry"/>'
            '</mxCell>' % (cid, html.escape(label, quote=True), BOX + style,
                           x, y, w, h))
        return cid

    def text(self, x, y, w, h, label, style=TITLE):
        cid = self._id()
        self.cells.append(
            '<mxCell id="%s" value="%s" style="%s" vertex="1" parent="1">'
            '<mxGeometry x="%d" y="%d" width="%d" height="%d" as="geometry"/>'
            '</mxCell>' % (cid, html.escape(label, quote=True), style,
                           x, y, w, h))
        return cid

    def edge(self, a, b, label="", style=EDGE):
        cid = self._id()
        self.cells.append(
            '<mxCell id="%s" value="%s" style="%s" edge="1" parent="1" '
            'source="%s" target="%s"><mxGeometry relative="1" as="geometry"/>'
            '</mxCell>' % (cid, html.escape(label, quote=True), style, a, b))
        return cid

    def xml(self, w, h):
        return ('<diagram name="%s" id="%s">'
                '<mxGraphModel dx="1200" dy="800" grid="1" gridSize="10" '
                'guides="1" tooltips="1" connect="1" arrows="1" fold="1" '
                'page="1" pageScale="1" pageWidth="%d" pageHeight="%d" '
                'math="0" shadow="0"><root>'
                '<mxCell id="0"/><mxCell id="1" parent="0"/>%s'
                '</root></mxGraphModel></diagram>'
                % (self.name, self.name.replace(" ", "-"), w, h,
                   "".join(self.cells)))


# ---------------------------------------------------------------- sheet 1
s1 = Sheet("SoC block diagram")
s1.text(30, 20, 700, 30, "m1core SoC  -  Tang Primer 25K  -  50 MHz, no PLL")
s1.text(30, 46, 900, 40,
        "two masters share the fabric: the DAP is m0 and wins arbitration, "
        "the CPU is m1.\ngenerated blocks come from boards/gw5a25/mcu.yaml.",
        NOTE)

bmp   = s1.box(30, 190, 110, 70, "Black Magic\nProbe\n(SWD)", EXT)
phy   = s1.box(180, 120, 120, 50, "swd_phy", DBG)
dp    = s1.box(180, 190, 120, 50, "sw_dp", DBG)
ap    = s1.box(180, 260, 120, 50, "mem_ap", DBG)

cpu   = s1.box(350, 150, 150, 130,
               "m1core_cpu_p\n\nARMv6-M\n3-stage F/D/E\n+ W writeback", CORE)
nvic  = s1.box(350, 300, 150, 46, "NVIC", CORE)

arb   = s1.box(550, 190, 120, 90, "ahb_arb\n\nm0 DAP\nm1 CPU", FAB)
fab   = s1.box(710, 175, 130, 120, "ahb_fabric\n\naddress\ndecode", FAB)

itcm  = s1.box(890, 40, 200, 50, "ITCM   32 KB\n0x0000_0000", MEM)
dtcm  = s1.box(890, 105, 200, 50, "DTCM   16 KB\n0x2000_0000", MEM)
gpio  = s1.box(890, 170, 200, 50, "GPIO0        irq 4\n0x4000_0000", PERIF)
brg   = s1.box(890, 235, 200, 50, "ahb_apb_bridge\n0x5000_0000", FAB)
ppb   = s1.box(890, 430, 200, 50, "PPB\n0xE000_0000", CORE)

apbx  = s1.box(890, 500, 200, 44,
               "APB expansion   16 x 1 MB\n0x6000_0000   disabled", OFF)
ahbx  = s1.box(890, 554, 200, 44,
               "AHB expansion   6 x 16 MB\n0x8000_0000   disabled", OFF)

tim   = s1.box(1140, 190, 170, 44, "TIMER0      irq 2\n0x5000_0000", PERIF)
uart  = s1.box(1140, 244, 170, 44, "UART0       irq 0\n0x5000_4000", PERIF)
rtc   = s1.box(1140, 298, 170, 44, "RTC         irq 6\n0x5000_6000", PERIF)

pins  = s1.box(1360, 170, 110, 50, "LED[3:0]\nGPIO[1:0]", EXT)
upins = s1.box(1360, 244, 110, 44, "UART_TX\nUART_RX", EXT)
clk   = s1.box(30, 300, 110, 60, "HCLK 50 MHz\nHRST (key,\nactive high)", EXT)

s1.edge(bmp, phy, "SWCLK/SWDIO")
s1.edge(phy, dp)
s1.edge(dp, ap)
s1.edge(ap, arb, "m0")
s1.edge(cpu, arb, "m1")
s1.edge(arb, fab, "AHB-Lite")
for t in (itcm, dtcm, gpio, brg, ppb):
    s1.edge(fab, t)
s1.edge(fab, apbx)
s1.edge(fab, ahbx)
for t in (tim, uart, rtc):
    s1.edge(brg, t, "APB")
s1.edge(gpio, pins)
s1.edge(uart, upins)
s1.edge(nvic, cpu, "", EDGE + "dashed=1;")
for src, lbl in ((gpio, "4"), (tim, "2"), (uart, "0"), (rtc, "6")):
    s1.edge(src, nvic, "irq " + lbl, IRQ)

# ---------------------------------------------------------------- sheet 2
s2 = Sheet("Memory map")
s2.text(30, 20, 700, 30, "m1core address map")
s2.text(30, 46, 800, 40,
        "generated into docs/memory-map.md from mcu.yaml. "
        "regions not listed read as zero rather than faulting.", NOTE)

rows = [
    ("0x0000_0000", "ITCM", "32 KB, instruction tightly coupled memory", MEM),
    ("0x2000_0000", "DTCM", "16 KB, data tightly coupled memory", MEM),
    ("0x4000_0000", "AHB peripherals", "GPIO0", PERIF),
    ("0x5000_0000", "APB peripherals", "TIMER0, UART0 +0x4000, RTC +0x6000",
     PERIF),
    ("0x6000_0000", "APB expansion", "16 slots x 1 MB   disabled", OFF),
    ("0x8000_0000", "AHB expansion", "6 slots x 16 MB   disabled", OFF),
    ("0xE000_0000", "PPB", "SCS, SysTick, NVIC, ROM table, debug", CORE),
]
y = 110
for addr, name, desc, style in rows:
    s2.box(30, y, 150, 46, addr, EXT)
    s2.box(190, y, 200, 46, name, style)
    s2.box(400, y, 380, 46, desc, style)
    y += 56

# ---------------------------------------------------------------- sheet 3
s3 = Sheet("Pipeline")
s3.text(30, 20, 700, 30, "m1core pipeline")
s3.text(30, 46, 900, 40,
        "three stages plus a delayed writeback. the W stage exists so the "
        "register file write is one cycle late,\nwhich is why both W and W2 "
        "are forwarded back into decode.", NOTE)

f = s3.box(60, 150, 150, 80, "F\nfetch\n\nqueue", CORE)
d = s3.box(250, 150, 150, 80, "D\ndecode\n\noperand select", CORE)
e = s3.box(440, 150, 150, 80, "E\nexecute\n\nalu / mem / mul", CORE)
w = s3.box(630, 150, 150, 80, "W\nwriteback\n\nw_data", FAB)
w2 = s3.box(820, 150, 150, 80, "W2\n\nw2_data", FAB)
rf = s3.box(630, 300, 340, 50, "register file   16 x 32   1 write, 4 read",
            MEM)

s3.edge(f, d)
s3.edge(d, e)
s3.edge(e, w)
s3.edge(w, w2)
s3.edge(w, rf, "write")
fwd = EDGE + "dashed=1;strokeColor=#C62828;"
s3.edge(w, d, "forward w_data", fwd)
s3.edge(w2, d, "forward w2_data", fwd)

doc = ('<mxfile host="app.diagrams.net" type="device">%s%s%s</mxfile>'
       % (s1.xml(1520, 640), s2.xml(850, 560), s3.xml(1050, 420)))
open(OUT, "w").write(doc)
print("wrote", OUT)
