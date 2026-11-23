# Basys 3 board peripherals

Blocks that exist only because this board has the hardware for them. They sit on
the APB expansion window of this board's own `mcu.yaml`, so the shared SoC in
`rtl/` never knows about them and the Tang builds are untouched.

| Block | Slot | Address | Registers | Pins |
| --- | --- | --- | --- | --- |
| `sevenseg.v` | apbexp0 | `0x60000000` | `sevenseg_regs.yaml` | `an[3:0]`, `seg[6:0]`, `dp` |

## How a block is put together

```
sevenseg_regs.yaml   register map, the one thing you edit by hand
   | make regs (cheby)
   +--> sevenseg_regs.v   apb slave: decode, registers, readback. do not edit
   +--> sevenseg_regs.h   offsets, masks, a struct for firmware. do not edit
sevenseg.v           the block: instantiates sevenseg_regs, uses its outputs
tb/tb_sevenseg.sv    unit test, `make sevenseg` in sim/
```

cheby writes the bus logic, so a block's own RTL only consumes the register
outputs (`ctrl_en_o`, `value_digits_o`, ...) and supplies the inputs of any
read-only registers. Firmware and RTL read the same YAML, so an offset cannot
drift between them.

## Adding a register

1. Add it to `<block>_regs.yaml`:

   ```yaml
       - reg:
           name: bright
           address: 0x10
           width: 32
           access: rw          # rw: firmware writes, rtl reads
           children:           # ro: rtl drives it, firmware reads
             - field:
                 name: level
                 range: 3-0
   ```

   Raise `size:` if the map grows past it.

2. Run `make regs` in `boards/xc7a35t_basys3`. `sevenseg_regs.v` gets a new
   port `bright_level_o` (an `_i` input for `ro`), and `sevenseg_regs.h` gets
   `SEVENSEG_REGS_BRIGHT` and the mask, plus a `bright` member in the struct.

3. Connect the new port in `sevenseg.v` and use it.

4. Extend `tb/tb_sevenseg.sv`: write it, read it back, check its effect on the
   pins. Run `make sevenseg` in `sim/`.

5. Use it from firmware: `SEVENSEG->bright = 3;`

6. `make prog` here, and the firmware as usual.

## Adding a new block

1. In `mcu.yaml`, raise `expansion: apb: enabled:` by one, then run `make gen`.
   The SoC gets a new set of `apbexpN_*` ports at `0x60000000 + N * 0x100000`.
2. Write `<block>_regs.yaml` with `bus: apb-32`, then run `make regs`.
3. Write `<block>.v`, copying the `u_regs` instance in `sevenseg.v`.
4. Add both `.v` files to the `lappend rtl` list in `../rtl.tcl`.
5. In `../top.v`, connect the `apbexpN_*` ports to the block (`penable`, `pwrite`,
   `paddr` and `pwdata` are shared by all slots; `psel`, `prdata` and `pready`
   are per slot). Add its pins to `../basys3.xdc`.
6. Write `tb/tb_<block>.sv` and add a target next to `sevenseg` in
   `sim/Makefile`.
7. In the Vivado GUI the project's file list is fixed when the project is
   created, so run `make project` once after steps 3 and 4.

## Tools

`cheby` is CERN's register generator, at `~/trunk/OSS/cheby`. `make regs` runs
`cheby` from your PATH. If that breaks, as it did after the move to Python 3.14,
run it from the source tree instead:

```
make regs CHEBY="env PYTHONPATH=$HOME/trunk/OSS/cheby/proto python3 -m cheby.main"
```

or reinstall it with `pip install --user --break-system-packages -e ~/trunk/OSS/cheby`.

`sim/` runs `make checkbasys3` as part of `checkgen`, which fails if `gen/` is
out of date with `mcu.yaml` or with the shared `rtl/mcu/m1core_mcu.v`.
