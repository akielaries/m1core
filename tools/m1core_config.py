#!/usr/bin/env python3
"""
m1core configurator, the same job Gowin's "Gowin EMPU M1" dialog does

it is deliberately a thin form over boards/<board>/mcu.yaml. every rule that
decides whether a configuration is legal lives in m1core_gen.validate(), which
this imports, so the gui cannot produce something the command line rejects and
there is no second copy of the rules to drift. pressing Generate runs exactly
the same four outputs sim/Makefile's checkgen target verifies.

what is on the palette is not a hardcoded list either: every tools/peripherals
/<type>.yaml becomes a block. adding a peripheral type to the generator makes it
appear here with no change to this file.

run:
    python3 tools/m1core_config.py [boards/gw5a25/mcu.yaml]
"""

import os
import subprocess
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import yaml

import m1core_gen as gen
import mcu_yaml

from PySide6.QtCore import Qt, QRect, Signal
from PySide6.QtGui import QColor, QFont, QPainter, QPen
from PySide6.QtWidgets import (
    QApplication, QComboBox, QFormLayout, QGroupBox, QHBoxLayout, QLabel,
    QLineEdit, QMainWindow, QMessageBox, QPlainTextEdit, QPushButton,
    QScrollArea, QSpinBox, QVBoxLayout, QWidget,
)

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PERIPH_DIR = os.path.join(REPO, "tools", "peripherals")

# peripherals that are wanted but not written yet, drawn greyed so the gap is
# visible. this is a to-do list, not a catalogue of everything gowin offers:
# can, ethernet, ddr3, sd-card and the rest are deliberately absent because
# nothing here needs them, and greying out blocks nobody wants just makes the
# diagram harder to read. writing the rtl plus a tools/peripherals/<type>.yaml
# moves an entry off this list and onto the palette automatically, which is why
# it is empty: spi, i2c and rtc were the list, and they are all implemented
PLANNED = {
    "ahb": [],
    "apb": [],
}

COL_ON      = QColor("#8ecae6")
COL_ON_SEL  = QColor("#219ebc")
COL_FREE    = QColor("#ffffff")
COL_PLANNED = QColor("#efefef")
COL_CORE    = QColor("#c7e9f1")

SLOT_W = 104   # per block, the width below which the labels stop being readable


def load_types():
    """every peripheral type the generator knows how to emit"""
    types = {}
    for fn in sorted(os.listdir(PERIPH_DIR)):
        if fn.endswith(".yaml"):
            with open(os.path.join(PERIPH_DIR, fn)) as f:
                t = yaml.safe_load(f)
            types[t["type"]] = t
    return types


def default_bus(t):
    """which bus a type belongs on, taken from its module name prefix"""
    mod = t.get("module", "")
    if mod.startswith("ahb_"):
        return "ahb"
    if mod.startswith("apb_"):
        return "apb"
    return "apb"


class Block:
    """one clickable box in the diagram"""

    def __init__(self, kind, label, bus, rect=None, periph=None, type_name=None):
        self.kind = kind          # instance | free | planned | core | itcm | dtcm
        self.label = label
        self.bus = bus
        self.rect = rect or QRect()
        self.periph = periph      # the mcu.yaml entry, for kind == instance
        self.type_name = type_name
        self.slot = None          # index, for kind == expansion


class Diagram(QWidget):
    """the block diagram, laid out like gowin's: core on top, then ahb, then apb"""

    selected = Signal(object)
    add_requested = Signal(str, str)
    planned_clicked = Signal(str)
    exp_add = Signal(str)
    exp_clicked = Signal(str, int)

    def __init__(self):
        super().__init__()
        self.blocks = []
        self.mcu = None
        self.types = {}
        self.sel_name = None
        self.bands = []
        self.core_rect = QRect()
        self.setMinimumHeight(430)

    def set_model(self, mcu, types):
        self.mcu = mcu
        self.types = types
        self.refresh()

    def refresh(self):
        """size to the widest row, so blocks keep a readable width and the
        scroll area scrolls rather than squeezing them"""
        if self.mcu is not None:
            widest = max([len(self._row_for(b)) for b in ("ahb", "apb")]
                         + [len(self._exp_row())])
            self.setMinimumWidth(max(560, widest * SLOT_W + 60))
            # the expansion band is only drawn when something is in it, so the
            # height has to follow the band count or it gets clipped
            bands = 2 + (1 if self._exp_row() else 0)
            self.setMinimumHeight(170 + bands * 122)
        self.update()

    def _layout(self):
        blocks = []
        self.bands = []
        w = self.width()
        pad = 14

        # --- core band -------------------------------------------------------
        core_h = 120
        cx, cy = pad + 10, pad + 22
        cw = w - 2 * (pad + 10)
        blocks.append(Block("band", "Cortex-M1 (m1core)", None,
                            QRect(cx, cy, cw, core_h)))
        # clustered around the spine rather than spread to the band edges: the
        # band is as wide as the widest peripheral row, and spreading put DTCM
        # off the right of the viewport with the core alone in the middle
        bw, bh = 92, 34
        mid = cy + core_h // 2 - bh // 2
        xm = cx + cw // 2
        itcm = self.mcu["cpu"]["itcm_kb"] if self.mcu else 0
        dtcm = self.mcu["cpu"]["dtcm_kb"] if self.mcu else 0
        blocks.append(Block("itcm", f"ITCM {itcm}K", None,
                            QRect(xm - 190, mid, bw, bh)))
        self.core_rect = QRect(xm - 70, mid, 140, bh)
        blocks.append(Block("core", "m1core", None, self.core_rect))
        blocks.append(Block("dtcm", f"DTCM {dtcm}K", None,
                            QRect(xm + 98, mid, bw, bh)))

        # --- peripheral bands ------------------------------------------------
        y = cy + core_h + 34
        for bus in ("ahb", "apb", "exp"):
            row = self._exp_row() if bus == "exp" else self._row_for(bus)
            if bus == "exp" and not row:
                continue
            band_h = 84 if bus != "exp" else 96
            title = ("Expansion - windows on the mcu top for your own logic"
                     if bus == "exp" else f"{bus.upper()} Bus")
            blocks.append(Block("band", title, bus, QRect(cx, y, cw, band_h)))
            self.bands.append(QRect(cx, y, cw, band_h))
            n = max(len(row), 1)
            slot = max(SLOT_W, (cw - 24) // n) if n * SLOT_W <= cw - 24 else SLOT_W
            bx = cx + 12
            for b in row:
                b.rect = QRect(bx + 4, y + 30, slot - 8,
                               54 if bus == "exp" else 42)
                blocks.append(b)
                bx += slot
            y += band_h + 26
            if bus == "ahb":
                blocks.append(Block("bridge", "AHB2APB", None,
                                    QRect(cx + cw // 2 - 46, y - 22, 92, 20)))

        return blocks

    def _row_for(self, bus):
        """what is actually instantiated on this bus, nothing else"""
        row = []
        for p in self.mcu.get("peripherals", []) if self.mcu else []:
            if p.get("bus") != bus:
                continue
            row.append(Block("instance", p["name"], bus, periph=p,
                             type_name=p["type"]))
        for name in PLANNED.get(bus, []):
            row.append(Block("planned", name, bus, type_name=name))
        return row

    def _exp_row(self):
        """every expansion window, both buses, in one band"""
        row = []
        for bus in ("ahb", "apb"):
            for name, base, size in gen.expansion_slots(self.mcu, bus):
                b = Block("expansion",
                          f"{name}\n0x{base:08X}\n{gen._size_str(size)}", bus)
                b.slot = int(name.replace(f"{bus}exp", ""))
                row.append(b)
            cfg = (self.mcu.get("expansion", {}) or {}).get(bus) or {}
            if int(cfg.get("enabled", 0)) < int(cfg.get("slots", 0)):
                row.append(Block("addexp", f"+ {bus} master", bus))
        return row

    def paintEvent(self, _ev):
        if self.mcu is None:
            return
        self.blocks = self._layout()
        p = QPainter(self)
        p.setRenderHint(QPainter.Antialiasing)
        p.fillRect(self.rect(), QColor("#ffffff"))

        small = QFont(self.font())
        small.setPointSizeF(max(7.0, self.font().pointSizeF() - 1.5))

        # spine from the core down through each band
        if self.bands:
            xm = self.bands[0].center().x()
            p.setPen(QPen(QColor("#666666"), 1))
            top = self.core_rect.bottom()
            p.drawLine(xm, top, xm, self.bands[-1].top())

        for b in self.blocks:
            if b.kind == "band":
                p.setPen(QPen(QColor("#c94f4f"), 1, Qt.DashLine))
                p.setBrush(Qt.NoBrush)
                p.drawRect(b.rect)
                p.setPen(QColor("#444444"))
                p.setFont(small)
                p.drawText(b.rect.x() + 8, b.rect.y() + 16, b.label)
                continue

            if b.kind == "instance":
                fill = COL_ON_SEL if b.periph["name"] == self.sel_name else COL_ON
                edge = QColor("#14607a")
            elif b.kind == "free":
                fill, edge = COL_FREE, QColor("#7a7a7a")
            elif b.kind == "planned":
                fill, edge = COL_PLANNED, QColor("#c0c0c0")
            elif b.kind == "expansion":
                fill, edge = QColor("#ffe3b0"), QColor("#b07d2a")
            elif b.kind == "addexp":
                fill, edge = COL_FREE, QColor("#b07d2a")
            elif b.kind == "bridge":
                fill, edge = QColor("#ffffff"), QColor("#666666")
            else:
                fill, edge = COL_CORE, QColor("#14607a")

            p.setBrush(fill)
            p.setPen(QPen(edge, 1,
                          Qt.DashLine if b.kind in ("free", "addexp")
                          else Qt.SolidLine))
            p.drawRect(b.rect)

            p.setPen(QColor("#9a9a9a") if b.kind == "planned" else QColor("#111111"))
            p.setFont(small)
            box = b.rect.adjusted(2, 0, -2, -12) if (
                b.kind == "instance" and b.periph.get("irq") is not None) else b.rect
            p.drawText(box, Qt.AlignCenter | Qt.TextWordWrap, b.label)

            # irq number in the corner, the thing most worth seeing at a glance
            if b.kind == "instance" and b.periph.get("irq") is not None:
                p.setPen(QColor("#0b4a5e"))
                p.drawText(b.rect.adjusted(0, 0, 0, -3),
                           Qt.AlignHCenter | Qt.AlignBottom,
                           f"irq {b.periph['irq']}")
        p.end()

    def mousePressEvent(self, ev):
        for b in self.blocks:
            if b.kind == "expansion" and b.rect.contains(ev.pos()):
                self.exp_clicked.emit(b.bus, b.slot)
                return
            if b.kind == "addexp" and b.rect.contains(ev.pos()):
                self.exp_add.emit(b.bus)
                return
            if b.kind not in ("band", "bridge") and b.rect.contains(ev.pos()):
                if b.kind == "instance":
                    self.sel_name = b.periph["name"]
                    self.selected.emit(b.periph)
                elif b.kind == "free":
                    self.add_requested.emit(b.type_name, b.bus)
                elif b.kind == "planned":
                    self.planned_clicked.emit(b.type_name)
                self.update()
                return
        self.sel_name = None
        self.selected.emit(None)
        self.update()


class Config(QMainWindow):

    def __init__(self, path):
        super().__init__()
        self.path = path
        self.types = load_types()
        self.std = gen.load_standard()
        self.mcu, self.ctx = mcu_yaml.load(path)
        self.setWindowTitle(f"m1core configurator - {os.path.relpath(path, REPO)}")

        root = QWidget()
        outer = QVBoxLayout(root)

        # --- general ---------------------------------------------------------
        g = QGroupBox("General")
        form = QFormLayout(g)
        self.f_name = QLineEdit(self.mcu["name"])
        self.f_board = QLineEdit(os.path.relpath(os.path.dirname(path), REPO))
        self.f_board.setReadOnly(True)
        self.f_lang = QComboBox()
        self.f_lang.addItem("Verilog 2001")
        self.f_lang.setEnabled(False)   # gowin synthesis rejects systemverilog
        form.addRow("Name:", self.f_name)
        form.addRow("Board:", self.f_board)
        form.addRow("Language:", self.f_lang)

        c = QGroupBox("Core")
        cform = QFormLayout(c)
        self.f_itcm = QSpinBox()
        self.f_itcm.setRange(1, 512)
        self.f_itcm.setValue(self.mcu["cpu"]["itcm_kb"])
        self.f_dtcm = QSpinBox()
        self.f_dtcm.setRange(1, 512)
        self.f_dtcm.setValue(self.mcu["cpu"]["dtcm_kb"])
        self.f_clk = QSpinBox()
        self.f_clk.setRange(1, 400)
        self.f_clk.setSuffix(" MHz")
        self.f_clk.setValue(int(self.mcu["clock"]["hz"] // 1_000_000))
        cform.addRow("ITCM:", self.f_itcm)
        cform.addRow("DTCM:", self.f_dtcm)
        cform.addRow("Clock:", self.f_clk)

        e = QGroupBox("Expansion (your own logic)")
        eform = QFormLayout(e)
        self.f_exp = {}
        for bus in ("ahb", "apb"):
            cfg = self.mcu.get("expansion", {}).get(bus) or {}
            sb = QSpinBox()
            sb.setRange(0, int(cfg.get("slots", 0)))
            sb.setValue(int(cfg.get("enabled", 0)))
            sb.setSuffix(f" of {cfg.get('slots', 0)}")
            sz = int(cfg.get("size_kb", 0)) * 1024
            sb.setToolTip(f"{cfg.get('slots', 0)} windows of "
                          f"{gen._size_str(sz)} at {int(cfg.get('base', 0)):#010x}")
            sb.valueChanged.connect(self.pull_general)
            self.f_exp[bus] = sb
            eform.addRow(f"{bus.upper()} masters:", sb)
        e.setToolTip("windows brought out on the mcu top for your own logic")

        top = QHBoxLayout()
        top.addWidget(g, 2)
        top.addWidget(c, 1)
        top.addWidget(e, 1)
        outer.addLayout(top)

        # --- diagram + inspector ---------------------------------------------
        self.diagram = Diagram()
        self.diagram.set_model(self.mcu, self.types)
        self.diagram.selected.connect(self.on_select)
        self.diagram.add_requested.connect(self.on_add)
        self.diagram.planned_clicked.connect(self.on_planned)
        self.diagram.exp_add.connect(self.on_exp_add)
        self.diagram.exp_clicked.connect(self.on_exp_clicked)

        scroll = QScrollArea()
        scroll.setWidget(self.diagram)
        scroll.setWidgetResizable(True)

        self.insp = QGroupBox("Peripheral")
        iform = QFormLayout(self.insp)
        self.i_name = QLineEdit()
        self.i_base = QLineEdit()
        self.i_irq = QSpinBox()
        self.i_irq.setRange(-1, 31)
        self.i_irq.setSpecialValueText("none")
        self.i_width = QSpinBox()
        self.i_width.setRange(1, 32)
        self.i_remove = QPushButton("Remove")
        iform.addRow("Name:", self.i_name)
        iform.addRow("Base:", self.i_base)
        iform.addRow("IRQ:", self.i_irq)
        iform.addRow("Width:", self.i_width)
        iform.addRow(self.i_remove)
        self.insp.setEnabled(False)
        self.sel = None

        palette = QHBoxLayout()
        palette.addWidget(QLabel("Add:"))
        self.add_btns = {}
        for name in sorted(self.types):
            btn = QPushButton(name)
            btn.clicked.connect(
                lambda _checked=False, n=name: self.on_add(n, default_bus(self.types[n])))
            palette.addWidget(btn)
            self.add_btns[name] = btn
        palette.addSpacing(16)
        for bus in ("ahb", "apb"):
            btn = QPushButton(f"{bus} master")
            btn.setToolTip(f"an expansion window for your own logic on the {bus} bus")
            btn.clicked.connect(lambda _checked=False, b=bus: self.on_exp_add(b))
            palette.addWidget(btn)
        palette.addStretch(1)

        left = QVBoxLayout()
        left.addWidget(scroll, 1)
        left.addLayout(palette)

        mid = QHBoxLayout()
        mid.addLayout(left, 3)
        mid.addWidget(self.insp, 1)
        outer.addLayout(mid, 1)

        # --- status + actions -------------------------------------------------
        self.status = QPlainTextEdit()
        self.status.setReadOnly(True)
        self.status.setMaximumHeight(96)
        outer.addWidget(self.status)

        row = QHBoxLayout()
        self.hint = QLabel("click a block to edit it, a dashed one to add it. "
                           "the orange windows are for attaching your own logic")
        row.addWidget(self.hint, 1)
        self.b_gen = QPushButton("Save and Generate")
        row.addWidget(self.b_gen)
        outer.addLayout(row)

        self.setCentralWidget(root)
        self.resize(1000, 780)

        for w in (self.f_name,):
            w.editingFinished.connect(self.pull_general)
        for w in (self.f_itcm, self.f_dtcm, self.f_clk):
            w.valueChanged.connect(self.pull_general)
        self.i_name.editingFinished.connect(self.pull_periph)
        self.i_base.editingFinished.connect(self.pull_periph)
        self.i_irq.valueChanged.connect(self.pull_periph)
        self.i_width.valueChanged.connect(self.pull_periph)
        self.i_remove.clicked.connect(self.on_remove)
        self.b_gen.clicked.connect(self.on_generate)

        self.revalidate()

    # -- model edits ---------------------------------------------------------

    def pull_general(self):
        self.mcu["name"] = self.f_name.text().strip()
        self.mcu["cpu"]["itcm_kb"] = self.f_itcm.value()
        self.mcu["cpu"]["dtcm_kb"] = self.f_dtcm.value()
        self.mcu["clock"]["hz"] = self.f_clk.value() * 1_000_000
        for bus, sb in self.f_exp.items():
            if bus in self.mcu.get("expansion", {}):
                self.mcu["expansion"][bus]["enabled"] = sb.value()
        self.diagram.refresh()
        self.revalidate()

    def pull_periph(self):
        if self.sel is None:
            return
        self.sel["name"] = self.i_name.text().strip()
        try:
            self.sel["base"] = int(self.i_base.text().strip(), 0)
        except ValueError:
            pass
        irq = self.i_irq.value()
        if irq < 0:
            self.sel.pop("irq", None)
        else:
            self.sel["irq"] = irq
        if "width" in self.sel:
            self.sel["width"] = self.i_width.value()
        self.diagram.sel_name = self.sel["name"]
        self.diagram.refresh()
        self.revalidate()

    def on_select(self, p):
        self.sel = p
        self.insp.setEnabled(p is not None)
        if p is None:
            return
        for w in (self.i_name, self.i_base, self.i_irq, self.i_width):
            w.blockSignals(True)
        self.i_name.setText(p["name"])
        self.i_base.setText(f"0x{p['base']:08X}")
        self.i_irq.setValue(p.get("irq", -1))
        self.i_width.setValue(p.get("width", 1))
        self.i_width.setEnabled("width" in p)
        for w in (self.i_name, self.i_base, self.i_irq, self.i_width):
            w.blockSignals(False)
        self.insp.setTitle(f"Peripheral - {p['type']}")

    def on_add(self, type_name, bus):
        t = self.types[type_name]
        std = self.standard_slot(type_name)
        if std:
            name, base, irq = std
            p = {"type": type_name, "name": name, "bus": bus, "base": base}
            if t.get("irq_port"):
                p["irq"] = irq if irq is not None else self.next_irq()
            self.hint.setText(
                f"{name} placed at 0x{base:08X}, its address in gowin's map")
        else:
            self.hint.setText(
                f"the standard map has no free {type_name} slot. add another "
                f"in an apb expansion window, where it gets its own address")
            return
        if type_name == "gpio":
            p["width"] = 2
        self.mcu.setdefault("peripherals", []).append(p)
        self.mcu["peripherals"].sort(key=lambda x: x["base"])
        self.diagram.sel_name = name
        self.on_select(p)
        self.diagram.refresh()
        self.revalidate()

    def on_remove(self):
        if self.sel is None:
            return
        self.mcu["peripherals"].remove(self.sel)
        self.sel = None
        self.diagram.sel_name = None
        self.insp.setEnabled(False)
        self.insp.setTitle("Peripheral")
        self.i_name.clear()
        self.i_base.clear()
        self.diagram.refresh()
        self.revalidate()

    def on_exp_add(self, bus):
        cfg = self.mcu["expansion"][bus]
        n = int(cfg.get("enabled", 0)) + 1
        cfg["enabled"] = n
        self.f_exp[bus].blockSignals(True)
        self.f_exp[bus].setValue(n)
        self.f_exp[bus].blockSignals(False)
        self.hint.setText(
            f"{bus}exp{n - 1} added. it comes out as "
            f"{'an ahb-lite slave' if bus == 'ahb' else 'an apb'} port group on "
            f"the mcu top for your own logic")
        self.diagram.refresh()
        self.revalidate()

    def on_exp_clicked(self, bus, slot):
        cfg = self.mcu["expansion"][bus]
        n = int(cfg.get("enabled", 0))
        size = int(cfg["size_kb"]) * 1024
        base = int(cfg["base"]) + slot * size
        if slot == n - 1:
            # only the last one can go, because removing a middle window would
            # renumber the ports every block below it is wired to
            cfg["enabled"] = n - 1
            self.f_exp[bus].blockSignals(True)
            self.f_exp[bus].setValue(n - 1)
            self.f_exp[bus].blockSignals(False)
            self.hint.setText(f"{bus}exp{slot} removed")
        else:
            self.hint.setText(
                f"{bus}exp{slot} at 0x{base:08X}, {gen._size_str(size)}. "
                f"remove the highest numbered window first, or the ports below "
                f"it renumber")
        self.diagram.refresh()
        self.revalidate()

    def on_planned(self, name):
        self.hint.setText(
            f"{name}: not implemented. add rtl and tools/peripherals/{name}.yaml "
            f"and it appears here automatically")

    # -- allocation ----------------------------------------------------------

    def standard_slot(self, type_name):
        """the next free entry of this type in gowin's map, if there is one

        placing a new block where gowin places it is the whole point of the
        standard map: a driver written for their core then works here at the
        same address, with the same interrupt number
        """
        used_names = {p["name"].upper() for p in self.mcu.get("peripherals", [])}
        used_irqs = {p.get("irq") for p in self.mcu.get("peripherals", [])}
        for e in self.std["peripherals"]:
            if e.get("type") != type_name or e["name"] in used_names:
                continue
            irq = e.get("irq")
            return e["name"].lower(), e["base"], (None if irq in used_irqs else irq)
        return None

    def next_name(self, type_name):
        used = {p["name"] for p in self.mcu.get("peripherals", [])}
        for i in range(32):
            n = f"{type_name}{i}"
            if n not in used:
                return n
        return type_name

    def next_base(self, bus, size):
        lo, hi = gen.BUS_WINDOW[bus]
        taken = []
        for p in self.mcu.get("peripherals", []):
            s = self.types[p["type"]].get("size", 0x1000)
            taken.append((p["base"], p["base"] + s))
        addr = lo
        while addr < hi:
            if not any(a < addr + size and addr < b for a, b in taken):
                return addr
            addr += size
        return lo

    def next_irq(self):
        """a free interrupt that is not one the standard map has spoken for

        without this, adding spi (which gowin gives no interrupt) took irq 1
        and pushed uart1 off its standard number when it was added later. an
        interrupt number is part of the compatibility contract, so anything
        without a standard one has to allocate around them
        """
        used = {p.get("irq") for p in self.mcu.get("peripherals", [])}
        reserved = {e["irq"] for e in self.std["peripherals"]
                    if e.get("irq") is not None}
        # named for a function in gowin's map even though no block here drives
        # them, so they are not free either
        reserved |= {5, 9}
        for i in range(32):
            if i not in used and i not in reserved:
                return i
        for i in range(32):
            if i not in used:
                return i
        return None

    # -- validation and output ------------------------------------------------

    def sync_palette(self):
        """grey out a type once the standard map has no slot left for it

        the map is what says there are two uarts, so the button follows it
        rather than a second list that could disagree
        """
        for name, btn in self.add_btns.items():
            free = self.standard_slot(name) is not None
            btn.setEnabled(free)
            total = sum(1 for e in self.std["peripherals"]
                        if e.get("type") == name)
            used = total - sum(1 for e in self.std["peripherals"]
                               if e.get("type") == name and
                               e["name"] not in {p["name"].upper()
                                                 for p in self.mcu.get("peripherals", [])})
            btn.setToolTip(
                self.types[name].get("doc", name) +
                f"\n{used} of {total} used" +
                ("" if free else ", the standard map has no more"))

    def revalidate(self):
        self.sync_palette()
        try:
            types = gen.load_periph_types(self.mcu)
            errors = gen.validate(self.mcu, types)
        except Exception as e:
            errors = [str(e)]
        if errors:
            self.status.setPlainText("\n".join(f"FAIL {e}" for e in errors))
            self.b_gen.setEnabled(False)
        else:
            n = len(self.mcu.get("peripherals", []))
            self.status.setPlainText(
                f"ok   {n} peripherals, configuration is valid\n"
                f"     Save and Generate writes {os.path.relpath(self.path, REPO)} "
                f"and regenerates the header, memory map and rtl")
            self.b_gen.setEnabled(True)
        return not errors

    def on_generate(self):
        if not self.revalidate():
            return
        mcu_yaml.save(self.path, self.mcu, self.ctx)
        cmd = [
            sys.executable, os.path.join(REPO, "tools", "m1core_gen.py"), self.path,
            "--header", os.path.join(REPO, "sw/baremetal/bsp/m1core.h"),
            "--memmap", os.path.join(REPO, "docs/memory-map.md"),
            "--apb-rtl", os.path.join(REPO, "rtl/mcu/m1core_apb.v"),
            "--mcu-rtl", os.path.join(REPO, "rtl/mcu/m1core_mcu.v"),
        ]
        r = subprocess.run(cmd, capture_output=True, text=True)
        out = (r.stdout + r.stderr).strip()
        if r.returncode:
            QMessageBox.critical(self, "Generate failed", out)
            return
        self.status.setPlainText(out + "\n\nnow rebuild the bitstream in the Gowin IDE")

        # a new peripheral type means a new rtl file the gowin project does not
        # list yet, and that only shows up as an elaboration error much later
        chk = subprocess.run([sys.executable, os.path.join(REPO, "tools/check_project.py")],
                             capture_output=True, text=True)
        if chk.returncode:
            self.status.appendPlainText(
                "\n" + (chk.stdout + chk.stderr).strip() +
                "\nadd the missing file to boards/<board>/m1core.gprj")


def main():
    path = sys.argv[1] if len(sys.argv) > 1 else os.path.join(
        REPO, "boards", "gw5a25", "mcu.yaml")
    if not os.path.exists(path):
        print(f"no such mcu description: {path}", file=sys.stderr)
        return 1
    app = QApplication(sys.argv[:1])
    win = Config(path)
    win.show()
    return app.exec()


if __name__ == "__main__":
    sys.exit(main())
