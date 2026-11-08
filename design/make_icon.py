"""App 图标：用 Meridian 自己渲染的地球（design/globe_render.png，无标签）套进 macOS 圆角方形。"""
from pathlib import Path
import numpy as np
from PIL import Image, ImageDraw, ImageFilter

D = Path(__file__).resolve().parent
src = Image.open(D / "globe_render.png").convert("RGB")
a = np.asarray(src).astype(int)
# 地球本体：比太空背景亮得多的像素
mask = a.sum(axis=2) > 300
# 只看穿过画面中心的一行一列，避开工具栏和按钮
h, w = mask.shape
row = np.where(mask[h // 2])[0]
col = np.where(mask[:, w // 2])[0]
r0 = (row.max() - row.min()) / 2
cx, cy = (row.min() + row.max()) / 2, col.max() - r0     # 顶部有工具栏，按底边算圆心
r = (row.max() - row.min()) / 2
m = r * 1.0                                   # 留出大气光晕
globe = src.crop((int(cx - m), int(cy - m), int(cx + m), int(cy + m))).resize((700, 700), Image.LANCZOS)  # 含光晕

S, inset = 1024, 100
icon = Image.new("RGBA", (S, S), (0, 0, 0, 0))
squircle = Image.new("L", (S, S), 0)
ImageDraw.Draw(squircle).rounded_rectangle((inset, inset, S - inset, S - inset), radius=185, fill=255)
bg = Image.new("RGBA", (S, S), (9, 12, 20, 255))
icon.paste(bg, (0, 0), squircle)
# 地球按圆形贴进去，边缘柔化
gm = Image.new("L", (700, 700), 0)
ImageDraw.Draw(gm).ellipse((0, 0, 699, 699), fill=255)
gm = gm.filter(ImageFilter.GaussianBlur(6))
layer = Image.new("RGBA", (S, S), (0, 0, 0, 0))
layer.paste(globe, (162, 162), gm)
icon = Image.alpha_composite(icon, Image.composite(layer, Image.new("RGBA", (S, S)), squircle))
icon.save(D / "appIcon.png")
