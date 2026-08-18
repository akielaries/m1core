#!/bin/sh
# the gowin flow without the ide
#
#   sh tools/gw.sh build  [board]   synthesis + place and route
#   sh tools/gw.sh timing [board]   summarise the last build's report
#   sh tools/gw.sh sram   [board]   load the bitstream into sram, lost on power off
#   sh tools/gw.sh flash  [board]   write it to flash, survives power off
#   sh tools/gw.sh probe            list attached cables
#
# board defaults to gw5a25.
#
# THIS DELIBERATELY NEVER CALLS set_option. set_option is not a per run
# override: it rewrites impl/<name>_process_config.json in place, and a session
# that walked the option space left this project on place_option=4 and
# TopModule=1 with no backup, because boards/*/impl is gitignored. change
# options in the ide, or use tools/pnr_sweep.py which snapshots and restores.

set -e
CMD=${1:-help}
BOARD=${2:-gw5a25}
ROOT=$(cd "$(dirname "$0")/.." && pwd)
IMPL=$ROOT/boards/$BOARD/impl

# newest ide that actually has gw_sh
IDE=$(ls -d "$HOME"/Downloads/Gowin_*/IDE 2>/dev/null | while read -r d; do
        [ -x "$d/bin/gw_sh" ] && echo "$d"; done | tail -1)

# gw_sh links the system qt and loses ("Cannot mix incompatible Qt library"),
# so the bundled one has to win. of the platform plugins only `minimal` works:
# offscreen wants GLX, linuxfb wants a tty. it still prints a
# createPlatformOpenGLContext warning and then runs
gwsh () {
  [ -n "$IDE" ] || { echo "no gowin ide with bin/gw_sh under ~/Downloads" >&2; exit 1; }
  QT_QPA_PLATFORM=minimal LD_LIBRARY_PATH="$IDE/lib" "$IDE/bin/gw_sh" "$@"
}

case "$CMD" in
  build)
    GPRJ=$ROOT/boards/$BOARD/m1core.gprj
    [ -f "$GPRJ" ] || { echo "no project at $GPRJ" >&2; exit 1; }
    TCL=$(mktemp); trap 'rm -f "$TCL"' EXIT
    printf 'open_project %s\nrun all\n' "$GPRJ" > "$TCL"
    cd "$ROOT" && gwsh "$TCL"
    sh "$0" timing "$BOARD"
    ;;

  timing)
    python3 - "$IMPL" <<'PY'
import glob, html, re, sys
hits = glob.glob(sys.argv[1] + "/pnr/*_tr_content.html")
if not hits:
    sys.exit("no timing report yet, run build first")
p = re.sub(r"\s+", " ", html.unescape(
    re.sub("<[^>]+>", " ", open(hits[0], errors="ignore").read())))

m = re.search(r"Part Number (\S+)", p)
print("part       ", m.group(1) if m else "?")
m = re.search(r"Setup Delay Model ([^N]*?) Hold", p)
print("corner     ", m.group(1).strip() if m else "?")

# the generated clock is the last constraint/fmax pair; the HCLK row measures
# the pll's own init flops and means nothing about the design
pairs = re.findall(r"([\d.]+)\(MHz\) ([\d.]+)\(MHz\) (\d+)", p)
if pairs:
    c, f, lv = pairs[-1]
    print("constraint %s MHz" % c)
    print("fmax       %s MHz   (%s logic levels)" % (f, lv))
for lbl, rx in (("setup viol", r"Numbers of Setup Violated Endpoints (\d+)"),
                ("hold viol ", r"Numbers of Hold Violated Endpoints (\d+)")):
    m = re.search(rx, p)
    print("%s %s" % (lbl, m.group(1) if m else "?"))
m = re.search(r"1 (-?[\d.]+) (\S+) (\S+)", p[p.find("Setup Paths Table"):][:4000])
if m:
    print("worst      %s ns  %s -> %s" % m.groups())
PY
    ;;

  sram|flash)
    FS=$(ls -t "$IMPL"/pnr/*.fs 2>/dev/null | head -1)
    [ -n "$FS" ] || { echo "no bitstream in $IMPL/pnr, run build first" >&2; exit 1; }
    echo "loading $FS"
    # openFPGALoader knows this board by name and needs no vendor install.
    # the gowin equivalent is
    #   Programmer/bin/programmer_cli -d GW5A-25A -r 2  --fsFile <fs>   sram
    #   Programmer/bin/programmer_cli -d GW5A-25A -r 5  --fsFile <fs>   flash
    # -r is --operation_index, `programmer_cli --help` lists all 30
    case "$BOARD" in
      gw5a25)    B=tangprimer25k ;;
      mega138k)  B=tangmega138k  ;;
      # openFPGALoader --list-boards has no tangmega60k. use the gowin
      # programmer for that one, or pass its ft2232 cable directly:
      #   openFPGALoader -c ft2232 --fpga-part GW5AT-60 <fs>
      mega60k)   echo "no openFPGALoader board for mega60k, see the note in \
this script" >&2; exit 1 ;;
      *)         echo "unknown board $BOARD" >&2; exit 1 ;;
    esac
    [ "$CMD" = flash ] && openFPGALoader -b "$B" -f "$FS" || openFPGALoader -b "$B" "$FS"
    ;;

  probe)  openFPGALoader --scan-usb ;;
  *)      sed -n '2,16p' "$0" | sed 's|^# \{0,1\}||' ;;
esac
