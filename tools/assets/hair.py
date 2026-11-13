"""Hair images for the outfield players, cut from the separate hair renders on the player sheets.

FigureBuilder gives every outfield player a transparent hair volume around the top of the head with a
decal on each face (HairTop / HairFront / HairBack / HairLeft / HairRight), so these images carry an
alpha matte: the sheet's dark navy backdrop and its grid are keyed out and the edge colours are
un-mixed from the backdrop so no navy halo is left. A slim opaque cap under the volume shows HairCap.
The head images get their blocky tile row (the old hair cap) repainted as hair, see paint_hair_band.
"""
import cv2
import numpy as np
from PIL import Image

# Boxes around the hair renders (sheet pixels). The profile views run into the head cross's tile
# columns, so their boxes stop at the column; that cut edge is the front of the head.
#   back   top-left render, the whole hairdo seen from behind
#   right  left of the head cross: strands sweep left (backwards), front on the right
#   left   right of the head cross: strands sweep right (backwards), front on the left
#   top    first of the three round renders in the right-hand column
RENDERS = {
    "main": dict(back=(4, 4, 262, 240), right=(250, 4, 432, 236), left=(824, 4, 1008, 236),
                 top=(996, 2, 1250, 202)),
    "rival9": dict(back=(4, 4, 262, 240), right=(250, 4, 426, 236), left=(830, 4, 1008, 236),
                   top=(996, 2, 1250, 202)),
    "teammate28": dict(back=(4, 4, 262, 240), right=(248, 4, 430, 236), left=(827, 4, 1008, 236),
                       top=(996, 2, 1250, 198), close=13),  # dreadlocks: dark gaps between the locks
    "teammate7": dict(back=(4, 4, 262, 240), right=(248, 4, 425, 236), left=(831, 4, 1008, 236),
                      top=(996, 2, 1250, 196)),
}


def _smoothstep(e0, e1, x):
    t = np.clip((x - e0) / (e1 - e0), 0.0, 1.0)
    return t * t * (3 - 2 * t)


def matte(sheet, box, close=5):
    """Cuts one hair render out of the sheet. Returns an RGBA PIL image (straight alpha) cropped to the
    hair's bounding box. `close` (px) bridges gaps between strands: anything enclosed after closing
    is kept as deep shadow."""
    x0, y0, x1, y1 = box
    rgb = np.asarray(sheet.convert("RGB"), np.float32)[y0:y1, x0:x1]
    border = np.concatenate([rgb[:3].reshape(-1, 3), rgb[-3:].reshape(-1, 3),
                             rgb[:, :3].reshape(-1, 3), rgb[:, -3:].reshape(-1, 3)])
    lum = rgb.mean(axis=2)
    border_lum = border.mean(axis=1)
    bg = np.median(border[border_lum < np.percentile(border_lum, 60)], axis=0)
    # Hair is brighter than the backdrop and/or warm (red over blue); the grid lines and the renders'
    # drop shadows are dark and still blue.
    warm = rgb[..., 0] - rgb[..., 2]
    score = np.maximum(lum - bg.mean(), 0) / 34.0 + np.maximum(warm, 0) / 20.0
    soft = _smoothstep(0.35, 1.0, score)

    # Silhouette: the biggest blob (closed so strands separated by thin shadows stay together), holes
    # filled, so the dark creases inside the hair stay opaque and stray grid specks go.
    solid = (soft > 0.5).astype(np.uint8)
    kernel = cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (close, close))
    solid = cv2.morphologyEx(solid, cv2.MORPH_CLOSE, kernel)
    n, labels, stats, _ = cv2.connectedComponentsWithStats(solid, 8)
    biggest = 1 + int(np.argmax(stats[1:, cv2.CC_STAT_AREA]))
    blob = (labels == biggest).astype(np.uint8)
    # Holes = background not reachable from outside the crop (padded, so a blob touching the crop
    # edge doesn't cut the outside in pieces).
    inv = np.pad(1 - blob, 1, constant_values=1).astype(np.uint8)
    cv2.floodFill(inv, None, (0, 0), 0)
    filled = blob | inv[1:-1, 1:-1]
    near = cv2.dilate(filled, np.ones((5, 5), np.uint8)).astype(np.float32)
    deep = cv2.erode(filled, np.ones((7, 7), np.uint8)).astype(np.float32)
    alpha = np.maximum(soft * near, deep)
    alpha = cv2.GaussianBlur(alpha, (3, 3), 0.6)
    alpha[alpha < 0.04] = 0

    # Un-mix the backdrop from the edge pixels; where alpha is too low to trust, take the colour of the
    # nearest solid hair instead. Backdrop that ends up inside the hair (creases) becomes hair shadow.
    a3 = np.maximum(alpha, 1e-3)[..., None]
    fg = np.clip((rgb - (1 - a3) * bg) / a3, 0, 255)
    unsure = ((alpha < 0.45) | (soft < 0.45)).astype(np.uint8)
    fg8 = cv2.inpaint(fg.astype(np.uint8), unsure, 4, cv2.INPAINT_TELEA).astype(np.float32)
    crease = (soft < 0.45) & (alpha >= 0.45)
    shade = np.where(crease, 0.3 + 0.7 * soft, 1.0)[..., None]
    fg = np.where(unsure[..., None] > 0, fg8 * shade, fg)

    ys, xs = np.nonzero(alpha > 0.04)
    cy0, cy1, cx0, cx1 = ys.min(), ys.max() + 1, xs.min(), xs.max() + 1
    out = np.dstack([fg, alpha * 255])[cy0:cy1, cx0:cx1]
    return Image.fromarray(np.round(out).astype(np.uint8), "RGBA")


def resize_rgba(img, size):
    """Premultiplied resize, so transparent pixels don't bleed their colour into the edges."""
    return img.convert("RGBa").resize(size, Image.LANCZOS).convert("RGBA")


def fit(img, size, pad=(0, 0, 0, 0)):
    """Stretches img into a transparent canvas of `size`, leaving pad = (left, top, right, bottom) as
    fractions of the canvas."""
    w, h = size
    l, t, r, b = pad
    inner = (max(1, round(w * (1 - l - r))), max(1, round(h * (1 - t - b))))
    canvas = Image.new("RGBA", size, (0, 0, 0, 0))
    canvas.paste(resize_rgba(img, inner), (round(w * l), round(h * t)))
    return canvas


def round_corners(img, top=0.0, bottom=0.0, side="both"):
    """Fades the top (and/or bottom) corners of a face image along an ellipse, so the volume's box
    corners don't show as a hard square silhouette. top/bottom: corner radius as a fraction of the
    height. side: which corners ("both", "left", "right")."""
    w, h = img.size
    a = np.asarray(img, np.float32).copy()
    yy, xx = np.mgrid[0:h, 0:w].astype(np.float32)
    keep = np.ones((h, w), np.float32)
    for frac, cy in ((top, 0.0), (bottom, float(h))):
        if frac <= 0:
            continue
        ry, rx = frac * h, frac * h * 1.4
        for cx, on in ((0.0, side in ("both", "left")), (float(w), side in ("both", "right"))):
            if not on:
                continue
            ex = np.clip(np.abs(xx - cx) / rx, 0, 1)  # 0 at the corner
            ey = np.clip(np.abs(yy - cy) / ry, 0, 1)
            inside = (ex < 1) & (ey < 1)
            d = np.sqrt((1 - ex) ** 2 + (1 - ey) ** 2)  # 0 on the ellipse's far side, >1 in the corner
            fade = np.clip((1.0 - d) / 0.25 + 1.0, 0, 1)
            keep = np.where(inside, np.minimum(keep, fade), keep)
    a[..., 3] *= keep
    return Image.fromarray(np.round(a).astype(np.uint8), "RGBA")


def fade_edge(img, edge, frac):
    """Linear alpha ramp over `frac` of the image at one edge ("left", "right", "bottom", "top")."""
    w, h = img.size
    a = np.asarray(img, np.float32).copy()
    n = max(1, round((w if edge in ("left", "right") else h) * frac))
    ramp = np.linspace(0, 1, n, endpoint=False) + 0.5 / n
    if edge == "left":
        a[:, :n, 3] *= ramp[None, :]
    elif edge == "right":
        a[:, w - n:, 3] *= ramp[::-1][None, :]
    elif edge == "top":
        a[:n, :, 3] *= ramp[:, None]
    else:
        a[h - n:, :, 3] *= ramp[::-1][:, None]
    return Image.fromarray(np.round(a).astype(np.uint8), "RGBA")


def flatten(img, shade=0.45):
    """RGBA matte -> RGB over a dark shade of the hair's own mean colour (for opaque hair textures)."""
    rgba = np.asarray(img, np.float32)
    a = rgba[..., 3:] / 255
    mean = (rgba[..., :3] * a).sum(axis=(0, 1)) / max(1.0, a.sum())
    out = rgba[..., :3] * a + mean * shade * (1 - a)
    return Image.fromarray(np.round(out).astype(np.uint8), "RGB")


def band_strip(back):
    """Hair texture for the band under the volume: the hanging strands in the middle of the back view."""
    w, h = back.size
    return flatten(back.crop((round(w * 0.12), round(h * 0.38), round(w * 0.88), round(h * 0.72))))


def solid_patch(img, size):
    """An opaque hair texture of `size` from the middle of a matte (for the cap under the volume)."""
    w, h = img.size
    a = np.asarray(img)[..., 3]
    ys, xs = np.nonzero(a > 250)
    cx, cy = int(np.median(xs)), int(np.median(ys))
    half_w, half_h = w // 4, h // 4
    crop = img.crop((cx - half_w, cy - half_h, cx + half_w, cy + half_h)).convert("RGB")
    return crop.resize(size, Image.LANCZOS)


def paint_hair_band(head, band, strip, feather=0.35, shade=0.82):
    """Repaints the top `band` rows of a head image (the sheet's blocky tile row) with the hair `strip`
    (an RGB image), darkened a little as it sits under the hair volume, and blends it into the original
    over the band's lower `feather` part."""
    w, h = head.size
    tex = np.asarray(strip.convert("RGB").resize((w, band), Image.LANCZOS), np.float32) * shade
    out = np.asarray(head.convert("RGB"), np.float32).copy()
    blend = np.ones(band, np.float32)
    n = max(1, round(band * feather))
    blend[band - n:] = np.linspace(1, 0, n + 2)[1:-1]
    out[:band] = tex * blend[:, None, None] + out[:band] * (1 - blend[:, None, None])
    return Image.fromarray(np.round(out).astype(np.uint8), "RGB")


def hair_set(sheet, key, sizes):
    """-> ({image key: PIL image}, {render name: matte}) for one sheet. The volume's faces get RGBA
    images; HairCap (the opaque cap under it) is RGB."""
    cfg = dict(RENDERS[key])
    close = cfg.pop("close", 5)
    m = {name: matte(sheet, box, close) for name, box in cfg.items()}
    images = {
        "HairFront": fit(m["top"], sizes["HairFront"]),
        "HairBack": fit(m["back"], sizes["HairBack"]),
        "HairRight": fit(m["right"], sizes["HairRight"]),
        "HairLeft": fit(m["left"], sizes["HairLeft"]),
        # Decals on a Top face have the image's top edge towards the part's Front; the render's
        # strand tips (its bottom) go to the front.
        "HairTop": fit(m["top"].transpose(Image.Transpose.FLIP_TOP_BOTTOM), sizes["HairTop"]),
        "HairCap": solid_patch(m["top"], sizes["HairCap"]),
    }
    return images, m


def quantise_rgba(img, colors=200, alpha_levels=4):
    """-> (indices bytes, palette [(r,g,b,a)]) with <= 256 entries. Alpha is snapped to `alpha_levels`
    levels; every fully transparent pixel shares one entry whose colour is the hair's mean edge colour
    (so bilinear filtering at the silhouette doesn't pull in black)."""
    rgba = np.asarray(img.convert("RGBA"))
    a = rgba[..., 3].astype(np.float32) / 255
    step = alpha_levels - 1
    aq = np.round(a * step).astype(np.int32)  # 0..step
    visible = aq > 0
    edge = visible & (aq < step)
    clear_rgb = rgba[..., :3][edge].mean(axis=0) if edge.any() else rgba[..., :3][visible].mean(axis=0)
    rgb = Image.fromarray(np.ascontiguousarray(rgba[..., :3]), "RGB")
    k = colors
    while True:
        q = rgb.quantize(colors=k, method=Image.Quantize.MEDIANCUT, dither=Image.Dither.NONE)
        qi = np.asarray(q).astype(np.int32)
        pal = q.getpalette()
        combo = np.where(visible, qi * (step + 1) + aq, -1)
        keys = np.unique(combo[visible])
        if len(keys) + 1 <= 256:
            break
        k = max(8, k - 16)
    palette = [(int(round(clear_rgb[0])), int(round(clear_rgb[1])), int(round(clear_rgb[2])), 0)]
    lookup = {}
    for key in keys:
        ci, lv = divmod(int(key), step + 1)
        lookup[int(key)] = len(palette)
        palette.append((pal[3 * ci], pal[3 * ci + 1], pal[3 * ci + 2], round(255 * lv / step)))
    flat = combo.ravel()
    idx = np.zeros(flat.shape, np.uint8)
    for key, i in lookup.items():
        idx[flat == key] = i
    return idx.tobytes(), palette
