#!/usr/bin/env python3
"""Renders contact sheets of the generated Images modules laid out like the blocky figure
(front, back, left and right views) to /tmp/tex/preview_<Module>.png.
Usage: python3 tools/assets/preview_players.py [Module ...]"""
import os
import sys

from PIL import Image, ImageDraw

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import packed_image as P  # noqa: E402

IMAGES = os.path.join(HERE, "..", "..", "src", "ReplicatedStorage", "Shared", "Images")
OUT = "/tmp/tex"

# name, size, centre (from FigureBuilder.PARTS); image stems are <name-based>
PARTS = [
    ("LeftUpperLeg", (0.98, 1.05, 0.98), (-0.5, 1.475, 0)),
    ("RightUpperLeg", (0.98, 1.05, 0.98), (0.5, 1.475, 0)),
    ("LeftLowerLeg", (0.9, 0.6, 0.9), (-0.5, 0.65, 0)),
    ("RightLowerLeg", (0.9, 0.6, 0.9), (0.5, 0.65, 0)),
    ("LeftFoot", (1, 0.35, 1.2), (-0.5, 0.175, -0.1)),
    ("RightFoot", (1, 0.35, 1.2), (0.5, 0.175, -0.1)),
    ("LowerTorso", (2, 0.6, 1), (0, 2.3, 0)),
    ("UpperTorso", (2, 1.4, 1), (0, 3.3, 0)),
    ("LeftUpperArm", (0.9, 1, 0.9), (-1.45, 3.5, 0)),
    ("LeftLowerArm", (0.85, 0.75, 0.85), (-1.45, 2.625, 0)),
    ("LeftHand", (0.95, 0.75, 0.95), (-1.45, 1.875, 0)),
    ("RightUpperArm", (0.9, 1, 0.9), (1.45, 3.5, 0)),
    ("RightLowerArm", (0.85, 0.75, 0.85), (1.45, 2.625, 0)),
    ("RightHand", (0.95, 0.75, 0.95), (1.45, 1.875, 0)),
    ("Head", (1.4, 1.25, 1.3), (0, 4.625, 0)),
    ("Hair", (1.5, 0.34, 1.42), (0, 5.365, 0.03)),
]
# Print boxes (FigureBuilder.PRINTS) drawn as outlines: part, view, box
BOXES = {}


def face_key(part, view):
    if part in ("LeftFoot", "RightFoot"):
        return None
    if part == "Head":
        return "Head" + view
    if part == "Hair":
        return "Hair" + view
    return part + (view if view in ("Front", "Back") else "Side")


def render(module, scale=70):
    _, items = P.read_module(os.path.join(IMAGES, module + ".lua"))
    imgs = {}
    for k, b in items:
        w, h, rgba = P.decode(b)
        imgs[k] = Image.frombytes("RGBA", (w, h), rgba).convert("RGB")
    views = ["Front", "Back", "Left", "Right"]
    W, H = int(2.8 * scale), int(5.8 * scale)
    sheet = Image.new("RGB", (W * 4 + 50, H + 30), (70, 70, 90))
    d = ImageDraw.Draw(sheet)
    for vi, view in enumerate(views):
        ox = vi * (W + 10) + 10
        d.text((ox, 4), view, fill=(255, 255, 0))
        for name, size, centre in PARTS:
            sx, sy, sz = size
            cx, cy, cz = centre
            if view == "Front":
                wx, wy, sxc = sx, sy, -cx
            elif view == "Back":
                wx, wy, sxc = sx, sy, cx
            elif view == "Left":
                wx, wy, sxc = sz, sy, cz
            else:
                wx, wy, sxc = sz, sy, -cz
            x0 = ox + (W / 2) + (sxc - wx / 2) * scale
            y0 = 20 + (5.7 - (cy + wy / 2)) * scale
            box = (round(x0), round(y0), round(x0 + wx * scale), round(y0 + wy * scale))
            key = face_key(name, view)
            if key is None:
                d.rectangle(box, fill=(235, 235, 245), outline=(0, 0, 0))
                continue
            img = imgs[key].resize((box[2] - box[0], box[3] - box[1]), Image.LANCZOS)
            sheet.paste(img, box[:2])
    sheet.save(os.path.join(OUT, f"preview_{module}.png"))
    return sheet


if __name__ == "__main__":
    mods = sys.argv[1:] or ["PlayerMain", "Rival9", "Teammate28", "Teammate7", "RivalPlain"]
    for m in mods:
        render(m)
        print("wrote", os.path.join(OUT, f"preview_{m}.png"))
