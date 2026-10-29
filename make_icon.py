#!/usr/bin/env python3
"""Matcha Music icon: a white music note in a matcha-green bowl/cup ring on warm cream, glass gloss. Renders 1024 (+ Dark/Tinted)."""
from PIL import Image, ImageDraw, ImageFilter
import os
S = 2
W = 1024 * S
OUT = os.path.expanduser("~/workspace/matcha-music/MatchaMusic/Assets.xcassets/AppIcon.appiconset")
os.makedirs(OUT, exist_ok=True)

def render(bg_top, bg_bot, note_color, ring_color, gloss_alpha):
    img = Image.new("RGB", (W, W), bg_bot)
    grad = Image.new("RGB", (1, W))
    for y in range(W):
        t = y / W
        c = tuple(int(bg_top[i] + (bg_bot[i] - bg_top[i]) * t) for i in range(3))
        grad.putpixel((0, y), c)
    img.paste(grad.resize((W, W)), (0, 0))
    d = ImageDraw.Draw(img, "RGBA")
    cx, cy = W // 2, W // 2
    r = int(W * 0.335)
    # ring (cup rim)
    d.ellipse([cx - r, cy - r, cx + r, cy + r], outline=ring_color, width=int(W * 0.035))
    # music note: stem + flag + two heads
    stem_x = cx + int(W * 0.075)
    top_y = cy - int(W * 0.19)
    bot_y = cy + int(W * 0.10)
    d.line([stem_x, top_y, stem_x, bot_y], fill=note_color, width=int(W * 0.042))
    d.polygon([(stem_x, top_y), (stem_x + int(W * 0.14), top_y + int(W * 0.045)), (stem_x + int(W * 0.14), top_y + int(W * 0.13)), (stem_x, top_y + int(W * 0.085))], fill=note_color)
    hr = int(W * 0.085)
    d.ellipse([stem_x - hr * 2 + int(W*0.01), bot_y - int(hr * 0.72), stem_x + int(W*0.01), bot_y + int(hr * 0.72)], fill=note_color)
    stem2_x = cx - int(W * 0.13)
    d.line([stem2_x, top_y + int(W * 0.06), stem2_x, bot_y + int(W * 0.045)], fill=note_color, width=int(W * 0.042))
    d.ellipse([stem2_x - hr * 2 + int(W*0.01), bot_y + int(W*0.045) - int(hr * 0.72), stem2_x + int(W*0.01), bot_y + int(W*0.045) + int(hr * 0.72)], fill=note_color)
    d.line([stem2_x, top_y + int(W * 0.06), stem_x, top_y], fill=note_color, width=int(W * 0.042))
    # gloss
    gloss = Image.new("L", (W, W), 0)
    gd = ImageDraw.Draw(gloss)
    gd.ellipse([-W * 0.25, -W * 0.62, W * 1.25, W * 0.38], fill=gloss_alpha)
    gloss = gloss.filter(ImageFilter.GaussianBlur(W // 10))
    img = Image.composite(Image.new("RGB", (W, W), (255, 255, 255)), img, gloss)
    return img.resize((1024, 1024), Image.LANCZOS)

render((250, 246, 232), (233, 228, 205), (74, 103, 54), (106, 140, 74), 70).save(f"{OUT}/AppIcon1024.png")
render((24, 32, 20), (10, 14, 8), (196, 224, 168), (140, 180, 110), 26).save(f"{OUT}/AppIcon1024-Dark.png")
# tinted: grayscale-ish green on black
render((30, 30, 30), (8, 8, 8), (210, 210, 210), (170, 170, 170), 20).save(f"{OUT}/AppIcon1024-Tinted.png")
print("icons written to", OUT)
