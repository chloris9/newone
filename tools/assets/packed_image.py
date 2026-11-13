"""Packed image format used by ShotClient/ImageLoader.decode (little-endian).

base64 of: u16 width, u16 height, u16 palette size, palette (RGBA bytes), then LZ tokens over
palette indices: byte c < 128 -> c+1 literal indices follow; c >= 128 -> copy c-125 indices
(3..130) from a u16 offset back (offset may be smaller than the length: overlapping run).
"""
import base64
import re
import struct

MAX_LITERAL = 128
MIN_MATCH = 3
MAX_MATCH = 130
MAX_OFFSET = 65535


def decode(packed):
    """Faithful port of ImageLoader.decode -> (width, height, rgba bytes)."""
    data = base64.b64decode(packed + "=" * (-len(packed) % 4))
    width, height, colors = struct.unpack_from("<HHH", data, 0)
    palette_start = 6
    pos = palette_start + colors * 4
    end = len(data)
    count = width * height
    idx = bytearray(count)
    o = 0
    while pos < end and o < count:
        token = data[pos]
        pos += 1
        if token < 128:
            n = token + 1
            idx[o:o + n] = data[pos:pos + n]
            pos += n
            o += n
        else:
            n = token - 125
            frm = o - struct.unpack_from("<H", data, pos)[0]
            pos += 2
            for k in range(n):  # byte by byte so overlapping runs repeat
                idx[o + k] = idx[frm + k]
            o += n
    assert o == count, "image data is truncated"
    pal = data[palette_start:palette_start + colors * 4]
    out = bytearray(count * 4)
    for i in range(count):
        out[i * 4:i * 4 + 4] = pal[idx[i] * 4:idx[i] * 4 + 4]
    return width, height, bytes(out)


def _lz(indices):
    """Greedy LZ over index bytes with a hash chain on 3-byte keys."""
    n = len(indices)
    out = bytearray()
    lit = bytearray()
    heads = {}
    prev = [-1] * n

    def flush():
        i = 0
        while i < len(lit):
            chunk = lit[i:i + MAX_LITERAL]
            out.append(len(chunk) - 1)
            out.extend(chunk)
            i += len(chunk)
        lit.clear()

    def insert(p):
        if p + 2 < n:
            key = (indices[p], indices[p + 1], indices[p + 2])
            prev[p] = heads.get(key, -1)
            heads[key] = p

    i = 0
    while i < n:
        best_len = 0
        best_off = 0
        if i + 2 < n:
            key = (indices[i], indices[i + 1], indices[i + 2])
            cand = heads.get(key, -1)
            tries = 48
            limit = min(MAX_MATCH, n - i)
            while cand >= 0 and tries > 0 and i - cand <= MAX_OFFSET:
                length = 0
                while length < limit and indices[cand + length] == indices[i + length]:
                    length += 1
                if length > best_len:
                    best_len, best_off = length, i - cand
                    if length == limit:
                        break
                cand = prev[cand]
                tries -= 1
        if best_len >= MIN_MATCH:
            flush()
            out.append(best_len + 125)
            out.extend(struct.pack("<H", best_off))
            for k in range(best_len):
                insert(i + k)
            i += best_len
        else:
            lit.append(indices[i])
            insert(i)
            i += 1
    flush()
    return bytes(out)


def encode(width, height, indices, palette):
    """indices: bytes of width*height palette indices; palette: list of (r,g,b,a)."""
    assert len(indices) == width * height and len(palette) <= 256
    head = struct.pack("<HHH", width, height, len(palette))
    pal = b"".join(bytes(c) for c in palette)
    return base64.b64encode(head + pal + _lz(indices)).decode("ascii")


def encode_pil(img, colors=256, dither=False):
    """Quantise an RGB(A) PIL image to <= `colors` and pack it."""
    from PIL import Image
    rgb = img.convert("RGB")
    q = rgb.quantize(colors=colors, method=Image.Quantize.MEDIANCUT,
                     dither=Image.Dither.FLOYDSTEINBERG if dither else Image.Dither.NONE)
    pal = q.getpalette()[:3 * colors]
    used = max(q.getdata()) + 1
    palette = [(pal[3 * i], pal[3 * i + 1], pal[3 * i + 2], 255) for i in range(used)]
    return encode(rgb.width, rgb.height, q.tobytes(), palette)


def read_module(path):
    """Parse a generated Images module -> (header comment lines, [(key, base64)])."""
    text = open(path, encoding="utf-8").read()
    header = [l for l in text.splitlines() if l.startswith("--")]
    items = re.findall(r'\n\s*(?:\["([^"]+)"\]|([A-Za-z_][A-Za-z0-9_]*))\s*=\s*\[==\[([^\]]*)\]==\]', text)
    return header, [(a or b, c) for a, b, c in items]
