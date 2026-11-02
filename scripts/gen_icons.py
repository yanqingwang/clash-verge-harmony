#!/usr/bin/env python3
"""Generate the plain PNG icons required by app.json5 / module.json5."""
import struct, zlib, sys

def png(path, size, rgba):
    w = h = size
    raw = b''.join(b'\x00' + bytes(rgba) * w for _ in range(h))
    def chunk(t, d):
        c = struct.pack('>I', len(d)) + t + d
        return c + struct.pack('>I', zlib.crc32(t + d) & 0xffffffff)
    ihdr = struct.pack('>IIBBBBB', w, h, 8, 6, 0, 0, 0)
    data = (b'\x89PNG\r\n\x1a\n'
            + chunk(b'IHDR', ihdr)
            + chunk(b'IDAT', zlib.compress(raw, 9))
            + chunk(b'IEND', b''))
    with open(path, 'wb') as f:
        f.write(data)

base = sys.argv[1]
png(f'{base}/AppScope/resources/base/media/app_icon.png', 216, (16, 24, 32, 255))
png(f'{base}/entry/src/main/resources/base/media/icon.png', 114, (16, 24, 32, 255))
print('icons written')
