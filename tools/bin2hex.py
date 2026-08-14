#!/usr/bin/env python3
"""convert a raw binary into 32 bit little endian words, one hex word per line

that is the format $readmemh wants for a word addressed memory, which objcopy
-O verilog does not produce
"""

import sys


def main():
    if len(sys.argv) != 3:
        sys.exit("usage: bin2hex.py <input.bin> <output.hex>")

    with open(sys.argv[1], "rb") as f:
        data = f.read()

    # pad up to a word boundary so the last partial word is not dropped
    if len(data) % 4:
        data += b"\x00" * (4 - len(data) % 4)

    with open(sys.argv[2], "w") as f:
        for i in range(0, len(data), 4):
            word = int.from_bytes(data[i:i + 4], "little")
            f.write(f"{word:08x}\n")

    print(f"{sys.argv[2]}: {len(data) // 4} words")


if __name__ == "__main__":
    main()
