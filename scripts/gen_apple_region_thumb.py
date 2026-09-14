#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""生成 labs 缩略图：apple_region_compare.jpg（多地区版本对比矩阵）"""
import os

from PIL import Image, ImageDraw

OUT = os.path.join('assets', 'labs', 'thumbs', 'apple_region_compare.jpg')
REF = os.path.join('assets', 'labs', 'thumbs', 'crypto_toolbox.jpg')

if os.path.exists(REF):
    W, H = Image.open(REF).size
else:
    W, H = 1200, 675

BG = (11, 15, 20)
ACCENT = (122, 162, 255)
OK = (125, 240, 196)
NO = (255, 107, 107)
PARTIAL = (255, 199, 106)
LINE = (255, 255, 255, 40)

img = Image.new('RGB', (W, H), BG)
d = ImageDraw.Draw(img, 'RGBA')

# 背景光斑
for cx, cy, r, col in [
    (int(W * 0.85), int(-H * 0.18), int(W * 0.58), ACCENT),
    (int(W * 0.12), int(H * 1.05), int(W * 0.48), OK),
]:
    steps = 40
    for i in range(steps, 0, -1):
        rr = int(r * i / steps)
        a = int(46 * (1 - i / steps) ** 2)
        d.ellipse([cx - rr, cy - rr, cx + rr, cy + rr], fill=col + (a,))

# ---------- 左侧：设备剪影（iPhone / Watch） ----------
ph_w = int(W * 0.15)
ph_h = int(ph_w * 2.02)
px = int(W * 0.07)
py = int((H - ph_h) / 2) - int(H * 0.02)
d.rounded_rectangle([px, py, px + ph_w, py + ph_h], radius=int(ph_w * 0.22),
                    fill=(24, 30, 40), outline=(255, 255, 255, 70), width=3)
d.rounded_rectangle([px + 8, py + 8, px + ph_w - 8, py + ph_h - 8],
                    radius=int(ph_w * 0.19), fill=(14, 19, 26))
# 灵动岛
di_w = int(ph_w * 0.34)
d.rounded_rectangle([px + (ph_w - di_w) // 2, py + 20,
                     px + (ph_w + di_w) // 2, py + 34],
                    radius=7, fill=(6, 8, 11))
# 屏幕内的信号/地区示意
for i in range(4):
    by = py + int(ph_h * 0.30) + i * int(ph_h * 0.13)
    bw = int(ph_w * (0.62 - i * 0.07))
    col = OK if i % 2 == 0 else ACCENT
    d.rounded_rectangle([px + int(ph_w * 0.18), by,
                         px + int(ph_w * 0.18) + bw, by + int(ph_h * 0.045)],
                        radius=6, fill=col + (205,))

# Apple Watch
wa_w = int(W * 0.085)
wa_h = int(wa_w * 1.2)
wx = px + ph_w + int(W * 0.025)
wy = py + int(ph_h * 0.60)
d.rounded_rectangle([wx + int(wa_w * 0.34), wy - int(wa_h * 0.34),
                     wx + int(wa_w * 0.66), wy + wa_h + int(wa_h * 0.34)],
                    radius=10, fill=(255, 255, 255, 46))
d.rounded_rectangle([wx, wy, wx + wa_w, wy + wa_h], radius=int(wa_w * 0.32),
                    fill=(26, 33, 43), outline=(255, 255, 255, 80), width=3)
d.rounded_rectangle([wx + 7, wy + 7, wx + wa_w - 7, wy + wa_h - 7],
                    radius=int(wa_w * 0.27), fill=(14, 19, 26))
d.ellipse([wx + wa_w // 2 - 12, wy + wa_h // 2 - 12,
           wx + wa_w // 2 + 12, wy + wa_h // 2 + 12], fill=NO + (215,))

# ---------- 右侧：地区 × 功能 对比矩阵 ----------
cols = 6          # 地区数
rows = 4          # 功能数
gx0 = int(W * 0.42)
gy0 = int(H * 0.22)
gw = int(W * 0.50)
gh = int(H * 0.56)
cw = gw / cols
ch = gh / rows

# 表头（地区色标）
for c in range(cols):
    x0 = gx0 + c * cw
    d.rounded_rectangle([x0 + 6, gy0 - int(ch * 0.62),
                         x0 + cw - 6, gy0 - int(ch * 0.20)],
                        radius=6, fill=(255, 255, 255, 58))

# 网格线
for c in range(cols + 1):
    x = gx0 + c * cw
    d.line([x, gy0, x, gy0 + gh], fill=LINE, width=2)
for r in range(rows + 1):
    y = gy0 + r * ch
    d.line([gx0, y, gx0 + gw, y], fill=LINE, width=2)

# 单元格状态：支持 / 部分支持 / 不支持
STATE = [
    [1, 1, 1, 1, 1, 0],
    [1, 2, 1, 0, 1, 2],
    [1, 1, 0, 1, 2, 1],
    [0, 1, 2, 1, 1, 0],
]
COLOR = {1: OK, 2: PARTIAL, 0: NO}

for r in range(rows):
    for c in range(cols):
        st = STATE[r][c]
        col = COLOR[st]
        ccx = gx0 + c * cw + cw / 2
        ccy = gy0 + r * ch + ch / 2
        rad = min(cw, ch) * 0.28
        d.ellipse([ccx - rad, ccy - rad, ccx + rad, ccy + rad], fill=col + (58,))
        if st == 1:      # 勾
            d.line([ccx - rad * 0.48, ccy + rad * 0.02,
                    ccx - rad * 0.10, ccy + rad * 0.42], fill=col, width=6)
            d.line([ccx - rad * 0.10, ccy + rad * 0.42,
                    ccx + rad * 0.52, ccy - rad * 0.42], fill=col, width=6)
        elif st == 0:    # 叉
            d.line([ccx - rad * 0.40, ccy - rad * 0.40,
                    ccx + rad * 0.40, ccy + rad * 0.40], fill=col, width=6)
            d.line([ccx + rad * 0.40, ccy - rad * 0.40,
                    ccx - rad * 0.40, ccy + rad * 0.40], fill=col, width=6)
        else:            # 部分支持：横线
            d.rounded_rectangle([ccx - rad * 0.45, ccy - 4,
                                 ccx + rad * 0.45, ccy + 4],
                                radius=4, fill=col)

# 行标签占位（左侧短条）
for r in range(rows):
    y = gy0 + r * ch + ch / 2
    d.rounded_rectangle([gx0 - int(W * 0.075), y - 7,
                         gx0 - int(W * 0.014), y + 7],
                        radius=7, fill=(255, 255, 255, 52))

# 底部图例
lg_y = gy0 + gh + int(H * 0.055)
lg_x = gx0
for col in (OK, PARTIAL, NO):
    d.ellipse([lg_x, lg_y - 9, lg_x + 18, lg_y + 9], fill=col)
    d.rounded_rectangle([lg_x + 28, lg_y - 6, lg_x + int(W * 0.085), lg_y + 6],
                        radius=6, fill=(255, 255, 255, 52))
    lg_x += int(W * 0.14)

os.makedirs(os.path.dirname(OUT), exist_ok=True)
img.save(OUT, 'JPEG', quality=90, optimize=True)
print('saved', OUT, img.size)