#!/usr/bin/env python3
"""Changes to a slot image (`<name>.img`, the header and the image as a
slot holds them) that a bootloader bench writes into a slot.

    imgtool.py pend   IN OUT              set the pending word
    imgtool.py mark   IN OUT WORD...      set the named state words: pending,
                                          tried, confirmed
    imgtool.py flip   IN OUT OFF BIT      flip bit BIT of byte OFF
    imgtool.py trunc  IN OUT N            keep the first N bytes
    imgtool.py field  IN OUT OFF VALUE    set the u32 at OFF, then the CRC
    imgtool.py rehash IN OUT              the image's SHA-256 and the CRC
                                          recomputed, the signature kept
    imgtool.py big_s  IN OUT              S of the signature set to S + L,
                                          then the CRC
    imgtool.py show   IN                  the header's fields

The header's layout is docs/embedded/bootloader.md's.
"""

import hashlib
import struct
import sys

L = 2**252 + 27742317777372353535851937790883648493
PENDING = 0x444E4550
STATE_WORDS = {"pending": (0xF0, 0x444E4550), "tried": (0xF4, 0x44595254), "confirmed": (0xF8, 0x464E4F43)}


def crc32c(b):
    c = 0xFFFFFFFF
    for x in b:
        c ^= x
        for _ in range(8):
            c = (c >> 1) ^ 0x82F63B78 if c & 1 else c >> 1
    return c ^ 0xFFFFFFFF


def recrc(b):
    struct.pack_into("<I", b, 0x80, crc32c(bytes(b[:0x80])))


def main():
    op = sys.argv[1]
    b = bytearray(open(sys.argv[2], "rb").read())
    if op == "show":
        hb, n = struct.unpack_from("<HI", b, 6)
        print("magic=%08x version=%d header_bytes=%d image_bytes=%d" %
              (struct.unpack_from("<I", b, 0)[0], struct.unpack_from("<H", b, 4)[0], hb, n))
        print("flags=%d crc_ok=%d" % (struct.unpack_from("<I", b, 0x1C)[0],
                                      crc32c(bytes(b[:0x80])) == struct.unpack_from("<I", b, 0x80)[0]))
        return
    out = sys.argv[3]
    if op == "pend":
        struct.pack_into("<I", b, 0xF0, PENDING)
    elif op == "mark":
        for name in sys.argv[4:]:
            off, word = STATE_WORDS[name]
            struct.pack_into("<I", b, off, word)
    elif op == "flip":
        off, bit = int(sys.argv[4], 0), int(sys.argv[5])
        b[off] ^= 1 << bit
    elif op == "trunc":
        b = b[:int(sys.argv[4], 0)]
    elif op == "field":
        struct.pack_into("<I", b, int(sys.argv[4], 0), int(sys.argv[5], 0))
        recrc(b)
    elif op == "rehash":
        hb, n = struct.unpack_from("<HI", b, 6)
        b[0x20:0x40] = hashlib.sha256(bytes(b[hb:hb + n])).digest()
        recrc(b)
    elif op == "big_s":
        s = int.from_bytes(b[0x60:0x80], "little") + L
        b[0x60:0x80] = s.to_bytes(32, "little")
        recrc(b)
    else:
        sys.exit("imgtool.py: no operation " + op)
    open(out, "wb").write(bytes(b))


main()
