#!/usr/bin/env python3
"""Cuts the four Roblox-style player sheets (tools/assets/source/*_sheet.png) into the per-face
images used by FigureBuilder and writes src/ReplicatedStorage/Shared/Images/<Module>.lua.

Usage (needs Pillow, numpy, opencv-python-headless):  python3 tools/assets/build_players.py [--debug]

Sheet layout (1254x1254, same template for every sheet):
  head strip  y~245-420: [back-left][right side][front][left side][back-right]; the back image is
              back-right + back-left (the strip wraps). The tile row at its top is the hair cap.
  shirt band  y~535-855: [arm side][arm front][torso front][arm front][torso side][arm back]
              [torso back][arm back][arm side]. Front/back arm panels are left/right as seen from the
              camera, so the character's Right arm is the panel on the left in the front view.
  leg band    y~870-1235: [leg sides][shorts+socks front pair][back pair][leg sides]
Both arms and legs show skin below the sleeve/shorts; the sleeve/shorts part goes on the
UpperArm/UpperLeg, the cuff-to-wristband part on the LowerArm, socks on the LowerLeg.
"""
import os
import struct
import sys

import cv2
import numpy as np
from PIL import Image, ImageDraw

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import packed_image as P  # noqa: E402

ROOT = os.path.abspath(os.path.join(HERE, "..", ".."))
SRC = os.path.join(HERE, "source")
OUT = os.environ.get("NFS_OUT") or os.path.join(ROOT, "src", "ReplicatedStorage", "Shared", "Images")
COLORS = int(os.environ.get("NFS_COLORS", "128"))
TMP = "/tmp/tex"

# Same key order as the previous generated modules.
KEYS = [
    "HeadFront", "HeadBack", "HeadLeft", "HeadRight",
    "HairFront", "HairBack", "HairLeft", "HairRight",
    "UpperTorsoFront", "LowerTorsoFront", "UpperTorsoBack", "LowerTorsoBack",
    "UpperTorsoSide", "LowerTorsoSide",
    "RightUpperArmFront", "RightLowerArmFront", "RightHandFront",
    "LeftUpperArmFront", "LeftLowerArmFront", "LeftHandFront",
    "LeftUpperArmBack", "LeftLowerArmBack", "LeftHandBack",
    "RightUpperArmBack", "RightLowerArmBack", "RightHandBack",
    "LeftUpperArmSide", "LeftLowerArmSide", "LeftHandSide",
    "RightUpperArmSide", "RightLowerArmSide", "RightHandSide",
    "RightUpperLegFront", "LeftUpperLegFront", "RightLowerLegFront", "LeftLowerLegFront",
    "LeftUpperLegBack", "RightUpperLegBack", "LeftLowerLegBack", "RightLowerLegBack",
    "LeftUpperLegSide", "RightUpperLegSide", "LeftLowerLegSide", "RightLowerLegSide",
]

# Measured panel rectangles per sheet (pixels, x ranges inclusive-exclusive after a small inset).
SHEETS = {
    "main": dict(
        file="main_player_sheet.png",
        head_bottom=414,
        fringe=(465, 790),
        head=dict(bL=(267, 376), rs=(383, 528), f=(535, 716), ls=(725, 870), bR=(879, 989)),
        torso=dict(f=(277, 506), b=(751, 976), s=(604, 652)),
        arm=dict(fr=(184, 269), fl=(514, 594), bl=(662, 742), br=(982, 1069), wl=(48, 174), wr=(1078, 1205),
                 cuff=709, lower_end=839, hand=(718, 795)),
        leg=dict(skin_front=1053, skin_side=1053),
    ),
    "rival9": dict(
        file="rival9_sheet.png",
        head_bottom=417,
        fringe=(490, 765),
        head=dict(bL=(267, 380), rs=(387, 523), f=(530, 720), ls=(729, 867), bR=(874, 986)),
        torso=dict(f=(277, 500), b=(752, 976), s=(604, 650)),
        arm=dict(fr=(188, 262), fl=(511, 590), bl=(663, 741), br=(987, 1066), wl=(49, 171), wr=(1082, 1205),
                 cuff=712, lower_end=847, hand=(718, 796)),
        leg=dict(skin_front=1063, skin_side=1063),
    ),
    "teammate28": dict(
        file="teammate28_sheet.png",
        head_bottom=408,
        fringe=(505, 705),
        head=dict(bL=(270, 377), rs=(384, 522), f=(529, 682), ls=(689, 820), bR=(827, 983)),
        torso=dict(f=(274, 500), b=(749, 977), s=(603, 653)),
        arm=dict(fr=(181, 264), fl=(510, 592), bl=(663, 741), br=(987, 1073), wl=(49, 172), wr=(1082, 1205),
                 cuff=709, lower_end=841, hand=(716, 791)),
        leg=dict(skin_front=1059, skin_side=1055),
    ),
    "teammate7": dict(
        file="teammate7_sheet.png",
        head_bottom=414,
        fringe=(465, 765),
        head=dict(bL=(268, 377), rs=(384, 517), f=(524, 685), ls=(692, 825), bR=(832, 985)),
        torso=dict(f=(279, 502), b=(752, 976), s=(603, 653)),
        arm=dict(fr=(184, 270), fl=(511, 593), bl=(662, 743), br=(985, 1071), wl=(49, 173), wr=(1080, 1205),
                 cuff=723, lower_end=836, hand=(730, 784)),
        leg=dict(skin_front=1063, skin_side=1052),
    ),
}

# Leg-band panels shared by every sheet: front pair (character's Right leg is on the left),
# back pair (character's Left leg is on the left) and the side panel of each leg.
LEG_A, LEG_B = (367, 483), (497, 609)       # front: Right leg, Left leg
LEG_C, LEG_D = (644, 757), (771, 887)       # back: Left leg, Right leg
LEG_SIDE_R, LEG_SIDE_L = (82, 187), (1067, 1172)
LEG_TOP, LEG_BOOT = 872, 1154
HIPS = (874, 943)

PPU_HEAD, PPU_BODY, PPU_HAIR = (int(v) for v in os.environ.get("NFS_PPU", "92,76,64").split(","))

# Number / print areas painted out on the sheets that get text prints. Regions are in sheet pixels.
PAINT_OUT = {
    "teammate7": dict(
        chest=(352, 676, 432, 778), back=(812, 628, 912, 782), bars=(836, 538, 892, 616),
        shorts=(534, 942, 577, 1002), mode="light",
    ),
    "rival9": dict(
        chest=(356, 682, 422, 770), back=(814, 634, 912, 790), bars=(836, 538, 892, 630),
        shorts=(552, 942, 602, 1012), mode="light",
    ),
}

MODULES = {
    # module: (head sheet, kit sheet, paint out numbers, header description)
    "PlayerMain": ("main", "teammate7", True,
                   "Your player: head from main_player_sheet.png, navy team kit (numbers removed) from teammate7_sheet.png."),
    "Rival9": ("rival9", "rival9", False, "Rival #9 cut from rival9_sheet.png."),
    "Teammate28": ("teammate28", "teammate28", False, "Teammate #28 cut from teammate28_sheet.png."),
    "Teammate7": ("teammate7", "teammate7", False, "Teammate #7 cut from teammate7_sheet.png."),
    "RivalPlain": ("rival9", "rival9", True,
                   "Rival kit from rival9_sheet.png with the numbers removed (numbers are drawn as text), for the defenders."),
}

# Face sizes in studs, from FigureBuilder.PARTS (width, height).
FACE = {
    "Head": (1.4, 1.25), "HeadSide": (1.3, 1.25),
    "Torso": (2.0, 1.4), "TorsoSide": (1.0, 1.4), "Hips": (2.0, 0.6), "HipsSide": (1.0, 0.6),
    "UpperArm": (0.9, 1.0), "LowerArm": (0.85, 0.75), "Hand": (0.95, 0.75),
    "UpperLeg": (0.98, 1.05), "LowerLeg": (0.9, 0.6),
    "Hair": (1.5, 0.34), "HairSide": (1.42, 0.34),
}


def px(face, ppu):
    w, h = FACE[face]
    return max(8, round(w * ppu)), max(8, round(h * ppu))


class Cut:
    """One face: the sheet rectangles (joined left to right) and the output size."""

    def __init__(self, pieces, size):
        self.pieces = pieces
        self.size = size


def rect(xr, y0, y1):
    return (xr[0], y0, xr[1], y1)


def layout(c):
    """Key -> Cut for the sheet configuration c."""
    h, t, a, lg = c["head"], c["torso"], c["arm"], c["leg"]
    hb = c["head_bottom"]
    top = 248
    hair_rows = (252, 288)
    cuts = {}

    def put(key, pieces, face, ppu):
        cuts[key] = Cut(pieces, px(face, ppu))

    put("HeadFront", [rect(h["f"], top, hb)], "Head", PPU_HEAD)
    put("HeadBack", [rect(h["bR"], top, hb), rect(h["bL"], top, hb)], "Head", PPU_HEAD)
    put("HeadLeft", [rect(h["ls"], top, hb)], "HeadSide", PPU_HEAD)
    put("HeadRight", [rect(h["rs"], top, hb)], "HeadSide", PPU_HEAD)
    # Hair cap: the tile row, avoiding the fringe that overhangs it beside the face.
    lo, hi = c["fringe"]
    clean_r, clean_l = (h["rs"][0], lo), (hi, h["ls"][1])
    put("HairFront", [rect(h["bL"], *hair_rows), rect(h["bR"], *hair_rows)], "Hair", PPU_HAIR)
    put("HairBack", [rect(h["bR"], *hair_rows), rect(h["bL"], *hair_rows)], "Hair", PPU_HAIR)
    put("HairLeft", [rect(clean_l, *hair_rows), rect(h["bR"], *hair_rows)], "HairSide", PPU_HAIR)
    put("HairRight", [rect(clean_r, *hair_rows), rect(h["bL"], *hair_rows)], "HairSide", PPU_HAIR)

    ty0, ty1 = 551, 849
    put("UpperTorsoFront", [rect(t["f"], ty0, ty1)], "Torso", PPU_BODY)
    put("UpperTorsoBack", [rect(t["b"], ty0, ty1)], "Torso", PPU_BODY)
    put("UpperTorsoSide", [rect(t["s"], 592, ty1)], "TorsoSide", PPU_BODY)
    put("LowerTorsoFront", [rect(LEG_A, *HIPS), rect(LEG_B, *HIPS)], "Hips", PPU_BODY)
    put("LowerTorsoBack", [rect(LEG_C, *HIPS), rect(LEG_D, *HIPS)], "Hips", PPU_BODY)
    put("LowerTorsoSide", [rect(LEG_SIDE_R, HIPS[0], HIPS[0] + 66)], "HipsSide", PPU_BODY)

    arm_top, cuff = 592, a["cuff"]
    upper = (arm_top, cuff - 2)
    lower = (cuff + 1, a["lower_end"])
    hand = a["hand"]
    inset = 14
    # (side name, front panel, back panel, wide panel); Right arm = +X = left panel in front view
    sides = {
        "Right": (a["fr"], a["br"], a["wl"]),
        "Left": (a["fl"], a["bl"], a["wr"]),
    }
    for name, (fr, bk, wide) in sides.items():
        put(f"{name}UpperArmFront", [rect(fr, *upper)], "UpperArm", PPU_BODY)
        put(f"{name}UpperArmBack", [rect(bk, *upper)], "UpperArm", PPU_BODY)
        put(f"{name}UpperArmSide", [rect(wide, *upper)], "UpperArm", PPU_BODY)
        for face in ("Front", "Back", "Side"):
            put(f"{name}LowerArm{face}", [rect(wide, *lower)], "LowerArm", PPU_BODY)
            cuts[f"{name}Hand{face}"] = Cut([(wide[0] + inset, hand[0], wide[1] - inset, hand[1])], (56, 44))

    sf, ss = lg["skin_front"], lg["skin_side"]
    sock = (sf + 5, LEG_BOOT)
    legs = {  # key side name: (front panel, back panel, side panel)
        "Right": (LEG_A, LEG_D, LEG_SIDE_R),
        "Left": (LEG_B, LEG_C, LEG_SIDE_L),
    }
    for name, (fr, bk, sd) in legs.items():
        put(f"{name}UpperLegFront", [rect(fr, LEG_TOP, sf - 2)], "UpperLeg", PPU_BODY)
        put(f"{name}UpperLegBack", [rect(bk, LEG_TOP, sf - 2)], "UpperLeg", PPU_BODY)
        put(f"{name}UpperLegSide", [rect(sd, LEG_TOP, ss - 2)], "UpperLeg", PPU_BODY)
        put(f"{name}LowerLegFront", [rect(fr, *sock)], "LowerLeg", PPU_BODY)
        put(f"{name}LowerLegBack", [rect(bk, *sock)], "LowerLeg", PPU_BODY)
        put(f"{name}LowerLegSide", [rect(fr, *sock)], "LowerLeg", PPU_BODY)
    return cuts


def cut_image(sheet, cut):
    parts = [sheet.crop(p) for p in cut.pieces]
    height = max(p.height for p in parts)
    joined = Image.new("RGB", (sum(p.width for p in parts), height))
    x = 0
    for p in parts:
        joined.paste(p, (x, 0))
        x += p.width
    return joined.resize(cut.size, Image.LANCZOS)


def paint_out(sheet, name):
    """Removes the printed numbers (and the back collar bars) from a sheet; returns the new sheet and
    the glyph boxes found, as sheet pixel rectangles."""
    cfg = PAINT_OUT[name]
    arr = np.asarray(sheet.convert("RGB")).copy()
    mask = np.zeros(arr.shape[:2], np.uint8)
    boxes = {}
    for key in ("chest", "back", "bars", "shorts"):
        x0, y0, x1, y1 = cfg[key]
        reg = arr[y0:y1, x0:x1].astype(int)
        lum = reg.mean(axis=2)
        light = (lum > 150) & (reg.min(axis=2) > 120)
        ys, xs = np.nonzero(light)
        assert len(xs) > 40, f"no glyph pixels found for {name} {key}"
        boxes[key] = (x0 + xs.min(), y0 + ys.min(), x0 + xs.max() + 1, y0 + ys.max() + 1)
        mask[y0:y1, x0:x1][light] = 255
    mask = cv2.dilate(mask, np.ones((3, 3), np.uint8), iterations=3)
    bgr = cv2.cvtColor(arr, cv2.COLOR_RGB2BGR)
    fixed = cv2.inpaint(bgr, mask, 7, cv2.INPAINT_TELEA)
    return Image.fromarray(cv2.cvtColor(fixed, cv2.COLOR_BGR2RGB)), boxes


def fractional_boxes(boxes, cuts, pad=0.07):
    """PRINTS-style {x, y, w, h} fractions of the face image for each painted-out glyph."""

    def frac(box, key):
        cut = cuts[key]
        piece = cut.pieces[0]
        pw, ph = piece[2] - piece[0], piece[3] - piece[1]
        x0, y0, x1, y1 = box
        fx0, fx1 = (x0 - piece[0]) / pw, (x1 - piece[0]) / pw
        fy0, fy1 = (y0 - piece[1]) / ph, (y1 - piece[1]) / ph
        fx0, fx1 = max(0, fx0 - pad), min(1, fx1 + pad)
        fy0, fy1 = max(0, fy0 - pad), min(1, fy1 + pad)
        return tuple(round(float(v), 2) for v in (fx0, fy0, fx1 - fx0, fy1 - fy0))

    return {
        "ChestNumber": frac(boxes["chest"], "UpperTorsoFront"),
        "BackNumber": frac(boxes["back"], "UpperTorsoBack"),
        "BackBars": frac(boxes["bars"], "UpperTorsoBack"),
        "ShortsNumber": frac(boxes["shorts"], "LeftUpperLegFront"),
    }


def write_module(name, header, images):
    lines = ["-- Generated by tools/assets/build_players.py. Do not edit by hand.", f"-- {header}", "return {"]
    for key in KEYS:
        packed = images[key]
        assert "]==]" not in packed
        lines.append(f'\t["{key}"] = [==[')
        for i in range(0, len(packed), 160):
            lines.append(packed[i:i + 160])
        lines.append("]==],")
    lines.append("}")
    path = os.path.join(OUT, name + ".lua")
    with open(path, "w", encoding="utf-8", newline="\n") as f:
        f.write("\n".join(lines) + "\n")
    return path


def main():
    debug = "--debug" in sys.argv
    sheets = {k: Image.open(os.path.join(SRC, c["file"])).convert("RGB") for k, c in SHEETS.items()}
    cuts = {k: layout(c) for k, c in SHEETS.items()}
    cleaned, boxes_by_sheet = {}, {}
    for k in PAINT_OUT:
        cleaned[k], boxes_by_sheet[k] = paint_out(sheets[k], k)
        if debug:
            cleaned[k].save(f"{TMP}/clean_{k}.png")

    if debug:
        for k, c in SHEETS.items():
            im = sheets[k].copy()
            d = ImageDraw.Draw(im)
            for key, cut in cuts[k].items():
                for p in cut.pieces:
                    d.rectangle(p, outline=(255, 0, 255))
            im.save(f"{TMP}/overlay_{k}.png")

    report = {}
    for module, (head_sheet, kit_sheet, remove_numbers, header) in MODULES.items():
        kit_src = cleaned[kit_sheet] if remove_numbers else sheets[kit_sheet]
        images = {}
        total = 0
        for key in KEYS:
            if key.startswith(("Head", "Hair")):
                img = cut_image(sheets[head_sheet], cuts[head_sheet][key])
            else:
                img = cut_image(kit_src, cuts[kit_sheet][key])
            images[key] = P.encode_pil(img, COLORS, dither=False)
            total += img.width * img.height
            if debug:
                img.save(f"{TMP}/new/{module}_{key}.png")
        path = write_module(module, header, images)
        report[module] = total
        print(f"{module}: {total} px -> {path}")
        if remove_numbers:
            print("  print boxes:", fractional_boxes(boxes_by_sheet[kit_sheet], cuts[kit_sheet]))


if __name__ == "__main__":
    main()
