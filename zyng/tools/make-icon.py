#!/usr/bin/env python3
"""Рисует иконку приложения — то же слово Zyng, что и в шапке.

    python3 tools/make-icon.py        (запускать из папки zyng)

Иконка собирается кодом, а не лежит готовой картинкой: правится цвет или
толщина штриха — и результат пересобирается одной командой, без графического
редактора и без расхождений с логотипом в приложении.

Буква Z рисуется здесь теми же долями, что и ZyngZ в Zyng/ZyngMark.swift.
Меняешь одно — поменяй и другое, иначе иконка и шапка разойдутся.

Нужен Pillow:  pip3 install pillow
"""
from PIL import Image, ImageDraw, ImageFilter, ImageFont

S = 1024
W = S * 3

# --- фон: диагональный градиент плюс мягкий свет сверху слева ---
c1, c2 = (0x5B, 0x8C, 0xFF), (0x8B, 0x5C, 0xF0)
bg = Image.new("RGB", (W, W))
px = bg.load()
for y in range(W):
    ty = y / (W - 1)
    for x in range(0, W, 6):
        t = (x / (W - 1) + ty) / 2
        col = tuple(int(c1[i] + (c2[i]-c1[i])*t) for i in range(3))
        for k in range(6):
            if x + k < W: px[x + k, y] = col
glow = Image.new("L", (W, W), 0)
ImageDraw.Draw(glow).ellipse([-W*0.3, -W*0.5, W*0.8, W*0.5], fill=76)
bg = Image.composite(Image.new("RGB", (W, W), (255,255,255)), bg,
                     glow.filter(ImageFilter.GaussianBlur(W*0.14)))

# --- слово ---
art = Image.new("RGBA", (W, W), (0,0,0,0))
d = ImageDraw.Draw(art)
WHITE = (255,255,255,255)

font = ImageFont.truetype("/usr/share/fonts/truetype/liberation/LiberationSans-Bold.ttf",
                          int(W * 0.22))
box = d.textbbox((0, 0), "H", font=font)
cap = box[3] - box[1]
stroke = int(cap * 0.235)     # вес Z под вес шрифта: на глаз штрихи равны

base, left = W * 0.5, W * 0.12
top, zw = base - cap, cap * 0.80

def poly(pts):
    d.line(pts, fill=WHITE, width=stroke, joint="curve")
    for p in (pts[0], pts[-1]):
        d.ellipse([p[0]-stroke/2, p[1]-stroke/2, p[0]+stroke/2, p[1]+stroke/2], fill=WHITE)

poly([(left, top), (left+zw, top),
      (left+zw*0.36, top+cap*0.40), (left+zw*0.60, top+cap*0.52),
      (left, base), (left+zw, base)])
d.text((left + zw + cap*0.18, base), "yng", font=font, fill=WHITE, anchor="ls")

word = art.crop(art.getbbox())
target = int(W * 0.68)
word = word.resize((target, int(word.height * target / word.width)), Image.LANCZOS)

canvas = Image.new("RGBA", (W, W), (0,0,0,0))
pos = ((W - word.width)//2, (W - word.height)//2)

# Мягкая тень под словом — отделяет его от фона, не пачкая цвет.
shadow = Image.new("RGBA", (W, W), (0,0,0,0))
shadow.paste(word, (pos[0], pos[1] + int(W*0.012)), word)
shadow = shadow.filter(ImageFilter.GaussianBlur(W*0.018))
shadow.putalpha(shadow.getchannel("A").point(lambda v: int(v*0.35)))

canvas = Image.alpha_composite(canvas, shadow)
canvas.paste(word, pos, word)

out = Image.alpha_composite(bg.convert("RGBA"), canvas).convert("RGB").resize((S, S), Image.LANCZOS)
out.save("Zyng/Assets.xcassets/AppIcon.appiconset/Zyng-1024.png", "PNG")
out.resize((256,256), Image.LANCZOS).save("/tmp/preview5.png")
print("ok")
