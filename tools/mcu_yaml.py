"""
comment preserving read/write for a board's mcu.yaml

the configurator has to write this file back, and mcu.yaml is not a machine
scratch file: the comments in it explain why the clock is 25 MHz, why the irq
numbers follow gowin's, what the expansion windows are for. loading it with
pyyaml and dumping it back would silently delete all of that, which is a bad
trade for a gui that only ever changes a handful of values

so nothing is "dumped". the file is edited in place:

  - scalars (itcm_kb, clock hz, ...) are substituted on their own line
  - the peripherals block is regenerated, but the comment lines above each
    entry are captured on read and re-emitted with that entry, keyed by
    peripheral name

the acceptance test is round trip identity: read a file, write it back with
nothing changed, and the bytes must be unchanged. see test_roundtrip() at the
bottom, which sim/Makefile runs
"""

import re

import yaml


def load(path):
    """return (mcu dict, edit context to hand back to save)"""
    with open(path) as f:
        text = f.read()

    doc = yaml.safe_load(text)
    if "mcu" not in doc:
        raise ValueError(f"{path}: no top level 'mcu' key")

    lines = text.split("\n")
    start, end, leading, tail = _find_periph_block(lines)

    ctx = {
        "lines": lines,
        "periph_start": start,
        "periph_end": end,
        "leading": leading,   # peripheral name -> comment/blank lines above it
        "tail": tail,         # trailing lines of the block, kept as is
    }
    return doc["mcu"], ctx


def save(path, mcu, ctx):
    lines = list(ctx["lines"])

    # peripherals first: it is the only multi line edit, so doing it before the
    # scalars keeps the scalar line numbers valid
    block = []
    for p in mcu.get("peripherals", []):
        block.extend(ctx["leading"].get(p["name"], []))
        block.extend(_emit_periph(p))
    block.extend(ctx["tail"])
    lines[ctx["periph_start"]:ctx["periph_end"]] = block

    _set_scalar(lines, "name", 2, mcu["name"])
    _set_scalar(lines, "itcm_kb", 4, mcu["cpu"]["itcm_kb"])
    _set_scalar(lines, "dtcm_kb", 4, mcu["cpu"]["dtcm_kb"])
    _set_scalar(lines, "hz", 4, mcu["clock"]["hz"])

    with open(path, "w") as f:
        f.write("\n".join(lines))


# ---------------------------------------------------------------------------
# internals
# ---------------------------------------------------------------------------

# canonical field order. anything not listed keeps its own order after these,
# so a key this tool does not know about survives a round trip
_ORDER = ["type", "name", "bus", "base", "irq", "width"]


def _indent(line):
    return len(line) - len(line.lstrip())


def _find_periph_block(lines):
    """locate the peripherals list and split it into per entry leading comments

    the block is every following line that is blank or indented at least 4. the
    comment banner before 'expansion:' sits at indent 2, so it correctly ends
    the block rather than being swallowed as a trailing comment
    """
    start = None
    for i, line in enumerate(lines):
        if re.match(r"^  peripherals:\s*$", line):
            start = i + 1
            break
    if start is None:
        raise ValueError("no 'peripherals:' key at indent 2")

    end = start
    while end < len(lines):
        line = lines[end]
        if line.strip() and _indent(line) < 4:
            break
        end += 1

    leading = {}
    pending = []
    name = None
    for line in lines[start:end]:
        if re.match(r"^    -\s", line):
            # a new entry: whatever accumulated belongs above it
            name = None
            pending_for_entry = pending
            pending = []
            m = re.search(r"\bname:\s*(\S+)", line)
            if m:
                name = m.group(1)
            leading[_PENDING] = pending_for_entry
        elif name is None and re.match(r"^      name:\s", line):
            name = line.split(":", 1)[1].strip()
            leading[name] = leading.pop(_PENDING, [])
        elif not line.strip() or line.lstrip().startswith("#"):
            if name is None:
                pending.append(line)
            else:
                # blank/comment after an entry's fields: treat as leading for
                # whatever comes next
                pending.append(line)
                name = None
    leading.pop(_PENDING, None)

    return start, end, leading, pending


_PENDING = object()


def _emit_periph(p):
    keys = [k for k in _ORDER if k in p] + [k for k in p if k not in _ORDER]
    out = []
    for j, k in enumerate(keys):
        lead = "    - " if j == 0 else "      "
        out.append(f"{lead}{k}: {_fmt(k, p[k])}")
    return out


def _fmt(key, value):
    if key == "base":
        return f"0x{value:08X}"
    if isinstance(value, bool):
        return "true" if value else "false"
    return str(value)


def _set_scalar(lines, key, indent, value):
    pat = re.compile(r"^(" + " " * indent + re.escape(key) + r":\s*)(\S+)(.*)$")
    for i, line in enumerate(lines):
        m = pat.match(line)
        if m:
            lines[i] = f"{m.group(1)}{value}{m.group(3)}"
            return
    raise ValueError(f"no '{key}:' at indent {indent}")


# ---------------------------------------------------------------------------
# round trip test
# ---------------------------------------------------------------------------

def test_roundtrip(path):
    """read then write unchanged, and require the bytes to be identical

    this is the whole safety argument for editing the file in place, so it runs
    in the regression rather than being asserted in a comment
    """
    with open(path) as f:
        before = f.read()

    mcu, ctx = load(path)

    # writes through save(), the real path, so a bug in save() fails this test
    # rather than being masked by a reimplementation of it here
    import tempfile
    import os
    fd, tmp = tempfile.mkstemp(suffix=".yaml")
    os.close(fd)
    try:
        save(tmp, mcu, ctx)
        with open(tmp) as f:
            after = f.read()
    finally:
        os.remove(tmp)

    if before != after:
        import difflib
        diff = "\n".join(difflib.unified_diff(
            before.split("\n"), after.split("\n"),
            "on disk", "round tripped", lineterm=""))
        return f"round trip changed the file:\n{diff}"
    return None


if __name__ == "__main__":
    import sys
    err = test_roundtrip(sys.argv[1])
    if err:
        print(f"FAIL {err}")
        sys.exit(1)
    print(f"ok   {sys.argv[1]} survives a round trip unchanged")
