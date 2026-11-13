#!/usr/bin/env python3
"""Round-trip checks for packed_image.py.
Usage: python3 tools/assets/check_packed_image.py [module.lua ...]
With no arguments checks every Images module in src/ReplicatedStorage/Shared/Images."""
import glob
import os
import sys

from PIL import Image

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import packed_image as P  # noqa: E402

IMAGES = os.path.join(HERE, "..", "..", "src", "ReplicatedStorage", "Shared", "Images")


def exact_roundtrip(w, h, rgba):
    """Re-encodes decoded pixels losslessly (their own palette) and decodes them again."""
    pal = sorted(set(rgba[i:i + 4] for i in range(0, len(rgba), 4)))
    assert len(pal) <= 256
    lookup = {c: i for i, c in enumerate(pal)}
    idx = bytes(lookup[rgba[i:i + 4]] for i in range(0, len(rgba), 4))
    packed = P.encode(w, h, idx, [tuple(c) for c in pal])
    return P.decode(packed) == (w, h, rgba)


def main():
    paths = sys.argv[1:] or sorted(glob.glob(os.path.join(IMAGES, "*.lua")))
    for path in paths:
        _, items = P.read_module(path)
        ok = 0
        px = 0
        for key, packed in items:
            w, h, rgba = P.decode(packed)
            assert exact_roundtrip(w, h, rgba), f"{path} {key}: round trip differs"
            assert len(Image.frombytes("RGBA", (w, h), rgba).getcolors(1 << 20)) <= 256
            ok += 1
            px += w * h
        print(f"{os.path.basename(path)}: {ok} images, {px} px, round trip exact")


if __name__ == "__main__":
    main()
