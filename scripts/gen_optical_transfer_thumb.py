#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""生成 labs 缩略图：optical_transfer.jpg（发送端二维码 → 接收端摄像头）"""
import os
import random

from PIL import Image, ImageDraw

OUT = os.path.join('assets', 'labs', 'thumbs', 'optical_transfer.jpg')
REF = os.path.join('assets', 'labs', 'thumbs', 'crypto_toolbox.jpg')

# 与其它缩略图保持一致的尺寸
if os.path.exists(REF):
    W, H = Image.open(REF).size
else:
    W, H = 1200, 675

BG_TOP = (11, 15, 20)
ACCENT = (122, 162, 255)
ACCENT2 = (125, 240, 196)

img = Image.new('RGB', (W, H), BG_TOP)
d = ImageDraw.Draw(img, 'RGBA')

# 背景光斑
for cx, cy, r, col in [
    (int(W * 0.82), int(-H * 0.15), int(W * 0.55), ACCENT),
    (int(W * 0.15), int(H * 0.05), int(W * 0.45), ACCENT2),
]:
    steps = 40
    for i in range(steps, 0, -1):
        rr = int(r * i / steps)
        a = int(46 * (1 - i / steps) ** 2)
        d.ellipse([cx - rr, cy - rr, cx + rr, cy + rr], fill=col + (a,))

# ---------- 左侧：屏幕 + 二维码 ----------
random.seed(20260909)
scr_w = int(W * 0.34)
scr_h = int(scr_w * 0.78)
sx = int(W * 0.07)
sy = int((H - scr_h) / 2)
d.rounded_rectangle([sx, sy, sx + scr_w, sy + scr_h], radius=18,
                    fill=(20, 26, 34), outline=(255, 255, 255, 46), width=2)

# 二维码（伪随机模块 + 三个定位角）
q_side = int(scr_h * 0.74)
qx = sx + (scr_w - q_side) // 2
qy = sy + (scr_h - q_side) // 2
d.rounded_rectangle([qx - 10, qy - 10, qx + q_side + 10, qy + q_side + 10],
                    radius=8, fill=(255, 255, 255))
N = 25
cell = q_side / N


def is_finder(r, c):
    return (r < 7 and c < 7) or (r < 7 and c >= N - 7) or (r >= N - 7 and c < 7)


for r in range(N):
    for c in range(N):
        if is_finder(r, c):
            continue
        if random.random() < 0.48:
            x0 = qx + c * cell
            y0 = qy + r * cell
            d.rectangle([x0, y0, x0 + cell, y0 + cell], fill=(0, 0, 0))

for (br, bc) in [(0, 0), (0, N - 7), (N - 7, 0)]:
    x0 = qx + bc * cell
    y0 = qy + br * cell
    d.rectangle([x0, y0, x0 + 7 * cell, y0 + 7 * cell], fill=(0, 0, 0))
    d.rectangle([x0 + cell, y0 + cell, x0 + 6 * cell, y0 + 6 * cell], fill=(255, 255, 255))
    d.rectangle([x0 + 2 * cell, y0 + 2 * cell, x0 + 5 * cell, y0 + 5 * cell], fill=(0, 0, 0))

# 屏幕底座
base_w = int(scr_w * 0.42)
d.rectangle([sx + (scr_w - 22) // 2, sy + scr_h, sx + (scr_w + 22) // 2, sy + scr_h + 22],
            fill=(255, 255, 255, 40))
d.rounded_rectangle([sx + (scr_w - base_w) // 2, sy + scr_h + 20,
                     sx + (scr_w + base_w) // 2, sy + scr_h + 32],
                    radius=6, fill=(255, 255, 255, 52))

# ---------- 中间：光束 ----------
beam_x0 = sx + scr_w + int(W * 0.03)
beam_x1 = int(W * 0.66)
cy = sy + scr_h // 2
for i in range(9):
    off = int((i - 4) * scr_h * 0.045)
    a = int(150 - abs(i - 4) * 28)
    d.line([beam_x0, cy + off, beam_x1, cy + int(off * 0.55)],
           fill=ACCENT2 + (max(a, 20),), width=3)
for k in range(5):
    px = beam_x0 + (beam_x1 - beam_x0) * (k + 0.5) / 5
    d.ellipse([px - 6, cy - 6, px + 6, cy + 6], fill=ACCENT2 + (190,))

# ---------- 右侧：摄像头 ----------
cam_w = int(W * 0.2)
cam_h = int(cam_w * 0.62)
cx0 = int(W * 0.7)
cy0 = cy - cam_h // 2
d.rounded_rectangle([cx0, cy0, cx0 + cam_w, cy0 + cam_h], radius=16,
                    fill=(26, 33, 43), outline=(255, 255, 255, 60), width=2)
# 镜筒
lens_r = int(cam_h * 0.34)
lcx = cx0 + int(cam_w * 0.36)
lcy = cy0 + cam_h // 2
d.ellipse([lcx - lens_r, lcy - lens_r, lcx + lens_r, lcy + lens_r],
          fill=(12, 16, 22), outline=ACCENT + (220,), width=4)
d.ellipse([lcx - lens_r // 2, lcy - lens_r // 2, lcx + lens_r // 2, lcy + lens_r // 2],
          fill=ACCENT + (120,))
d.ellipse([lcx - lens_r // 5, lcy - lens_r // 2, lcx + lens_r // 8, lcy - lens_r // 6],
          fill=(255, 255, 255, 210))
# 录制指示灯
d.ellipse([cx0 + cam_w - 34, cy0 + 18, cx0 + cam_w - 18, cy0 + 34], fill=(255, 107, 107))
# 进度条（还原进度）
pb_x0 = cx0 + int(cam_w * 0.62)
pb_x1 = cx0 + cam_w - 18
pb_y = cy0 + cam_h - 26
d.rounded_rectangle([pb_x0, pb_y, pb_x1, pb_y + 10], radius=5, fill=(255, 255, 255, 45))
d.rounded_rectangle([pb_x0, pb_y, pb_x0 + int((pb_x1 - pb_x0) * 0.72), pb_y + 10],
                    radius=5, fill=ACCENT2)

# ---------- 还原出的文件卡片 ----------
fw, fh = int(W * 0.1), int(W * 0.125)
fx = cx0 + cam_w - int(fw * 0.35)
fy = cy0 - int(fh * 0.55)
d.rounded_rectangle([fx, fy, fx + fw, fy + fh], radius=10,
                    fill=(255, 255, 255, 235), outline=ACCENT2 + (255,), width=3)
d.polygon([(fx + fw - 26, fy), (fx + fw, fy + 26), (fx + fw - 26, fy + 26)],
          fill=(210, 220, 235))
for i in range(5):
    ly = fy + int(fh * 0.42) + i * int(fh * 0.1)
    d.rounded_rectangle([fx + 16, ly, fx + fw - (18 if i % 2 else 34), ly + 6],
                        radius=3, fill=(90, 105, 130))

os.makedirs(os.path.dirname(OUT), exist_ok=True)
img.save(OUT, 'JPEG', quality=90, optimize=True)
print('saved', OUT, img.size)