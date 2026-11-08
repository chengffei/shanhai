"""山海 App 图标。

构图：海水江崖。团扇形圆框（也是地球）里，青绿主峰从浪中升起，峰顶冲出圆框；朱日在右上。
山：峰头圆润、层层相叠；按青绿山水设色，山顶石青、山脚石绿，左亮右暗。
海：上为翻卷的平水，下为斜向的立水（海水江崖纹的两段）。
配色只用宣纸、石青、石绿、朱砂、泥金、靛墨，不放文字。4 倍超采样绘制。

用法：python icon_shanhai.py <输出 png> [审稿图目录]
"""
import math, sys
from pathlib import Path
from PIL import Image, ImageDraw, ImageChops, ImageFilter

K = 4
S = 1024 * K

PAPER = (240, 231, 212)
SKY = (228, 216, 191)
AZURE = (38, 86, 122)          # 石青
AZURE_LIGHT = (70, 122, 156)
AZURE_DEEP = (26, 62, 92)
GREEN = (78, 152, 126)         # 石绿
GREEN_DARK = (44, 108, 92)
GREEN_LIGHT = (124, 186, 156)
INK = (30, 44, 60)             # 靛墨
GOLD = (196, 160, 90)          # 泥金
CINNABAR = (200, 66, 46)
FOAM = (240, 232, 214)
HAZE = (190, 196, 186)         # 远山


def P(x, y):
    return (x * K, y * K)


def catmull(points, n=24, closed=False):
    """Catmull-Rom 平滑，输入 1024 坐标，输出画布坐标"""
    pts = list(points)
    if closed:
        pts = [pts[-1]] + pts + pts[:2]
    else:
        pts = [pts[0]] + pts + [pts[-1]]
    out = []
    for i in range(1, len(pts) - 2):
        p0, p1, p2, p3 = pts[i - 1], pts[i], pts[i + 1], pts[i + 2]
        for j in range(n):
            t = j / n
            t2, t3 = t * t, t * t * t
            x = 0.5 * ((2 * p1[0]) + (-p0[0] + p2[0]) * t + (2 * p0[0] - 5 * p1[0] + 4 * p2[0] - p3[0]) * t2 + (-p0[0] + 3 * p1[0] - 3 * p2[0] + p3[0]) * t3)
            y = 0.5 * ((2 * p1[1]) + (-p0[1] + p2[1]) * t + (2 * p0[1] - 5 * p1[1] + 4 * p2[1] - p3[1]) * t2 + (-p0[1] + 3 * p1[1] - 3 * p2[1] + p3[1]) * t3)
            out.append(P(x, y))
    out.append(P(*pts[-2]))
    return out


def mask(fn):
    m = Image.new("L", (S, S), 0)
    fn(ImageDraw.Draw(m))
    return m


def paint(base, color, m):
    im = Image.new("RGBA", (S, S), color + (255,))
    im.putalpha(m)
    return Image.alpha_composite(base, im)


def mul(*ms):
    out = ms[0]
    for m in ms[1:]:
        out = ImageChops.multiply(out, m)
    return out


# 每座峰：外轮廓（左脚 → 峰顶 → 右脚）、明暗分界线（峰顶 → 山脚）
PEAKS = [
    # 左后峰：瘦高，顶微偏右
    {"outline": [(244, 668), (262, 590), (286, 520), (304, 470), (318, 452), (330, 430), (350, 396), (368, 386), (384, 398),
                 (396, 430), (404, 470), (414, 520), (430, 590), (446, 668)],
     "ridge": [(368, 386), (374, 470), (390, 570), (402, 668)]},
    # 右后峰：矮一些，左肩带一个小峰
    {"outline": [(566, 668), (584, 590), (600, 530), (616, 494), (632, 486), (646, 462), (668, 432), (690, 426), (710, 444),
                 (724, 486), (740, 548), (756, 610), (772, 668)],
     "ridge": [(690, 426), (696, 500), (710, 590), (724, 668)]},
    # 主峰：峰头圆润微侧，左肩、右肩各一小峰
    {"outline": [(346, 668), (360, 600), (378, 540), (396, 492), (410, 468), (426, 456), (438, 430), (450, 380), (464, 316),
                 (478, 258), (494, 214), (514, 192), (536, 196), (552, 222), (562, 262), (572, 310), (588, 346), (604, 352),
                 (616, 378), (626, 430), (640, 500), (654, 580), (668, 668)],
     "ridge": [(522, 193), (528, 290), (542, 400), (560, 520), (580, 668)]},
]
SHAN_STROKES = [  # 皴：暗面上几道短弧，顺山势
    [(552, 260), (560, 300), (562, 334)], [(574, 420), (586, 460), (590, 496)], [(600, 540), (610, 576), (614, 606)],
    [(706, 500), (716, 540), (720, 572)], [(384, 470), (392, 510), (396, 544)],
]


def build():
    cx, cy, R = 512, 552, 296
    base = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    sq = mask(lambda d: d.rounded_rectangle((100 * K, 100 * K, 924 * K, 924 * K), radius=185 * K, fill=255))
    base = paint(base, PAPER, sq)
    disk = mask(lambda d: d.ellipse(P(cx - R, cy - R) + P(cx + R, cy + R), fill=255))
    shadow = mask(lambda d: d.ellipse(P(cx - R + 6, cy - R + 22) + P(cx + R - 6, cy + R + 22), fill=70)).filter(ImageFilter.GaussianBlur(22 * K))
    base = paint(base, (90, 70, 40), mul(sq, shadow))
    base = paint(base, SKY, disk)

    # 朱日
    base = paint(base, CINNABAR, mul(disk, mask(lambda d: d.ellipse(P(676 - 38, 388 - 38) + P(676 + 38, 388 + 38), fill=255))))

    # 远山：淡一层，衬出主山
    haze = catmull([(200, 600), (260, 540), (330, 520), (420, 548), (500, 520), (600, 500), (690, 530), (780, 512), (840, 560)])
    base = paint(base, HAZE, mul(disk, mask(lambda d: d.polygon(haze + [P(840, 900), P(200, 900)], fill=255))))

    # 山
    mountains = Image.new("L", (S, S), 0)
    for pk in PEAKS:
        outline = catmull(pk["outline"])
        ridge = catmull(pk["ridge"])
        whole = mask(lambda d: d.polygon(outline, fill=255))
        mountains = ImageChops.lighter(mountains, whole)
        # 左亮右暗：明暗分界线右侧为暗面
        right_of_ridge = mask(lambda d: d.polygon(ridge + [P(1000, 668), P(1000, 0), P(ridge[0][0] / K, 0)], fill=255))
        # 青绿设色：山顶石青，往下过渡到石绿（分三段，段间界线起伏）
        top_y = min(y for _, y in pk["outline"])
        soft = ImageFilter.GaussianBlur(26 * K)
        band1 = mask(lambda d: d.polygon(catmull([(0, top_y + 60), (300, top_y + 76), (600, top_y + 54), (1024, top_y + 70)]) + [P(1024, 0), P(0, 0)], fill=255)).filter(soft)
        band2 = mask(lambda d: d.polygon(catmull([(0, top_y + 150), (300, top_y + 170), (600, top_y + 140), (1024, top_y + 160)]) + [P(1024, 0), P(0, 0)], fill=255)).filter(soft)
        base = paint(base, GREEN_LIGHT, whole)
        base = paint(base, GREEN, mul(whole, right_of_ridge))
        base = paint(base, AZURE_LIGHT, mul(whole, band2, ImageChops.invert(right_of_ridge)))
        base = paint(base, AZURE, mul(whole, band2, right_of_ridge))
        base = paint(base, AZURE, mul(whole, band1, ImageChops.invert(right_of_ridge)))
        base = paint(base, AZURE_DEEP, mul(whole, band1, right_of_ridge))
        # 山脚暗面再压一层石绿暗
        foot = mask(lambda d: d.rectangle(P(0, 600) + P(1024, 700), fill=255)).filter(ImageFilter.GaussianBlur(20 * K))
        base = paint(base, GREEN_DARK, mul(whole, foot, right_of_ridge))
        d = ImageDraw.Draw(base)
        d.line(ridge, fill=GOLD + (255,), width=5 * K, joint="curve")
        d.line(outline, fill=INK + (255,), width=6 * K, joint="curve")
    d = ImageDraw.Draw(base)
    for st in SHAN_STROKES:
        d.line(catmull(st, 10), fill=(28, 84, 70, 255), width=4 * K, joint="curve")

    # 海：平水（翻卷浪头）+ 立水（斜条）
    sea_top = 618
    sea = mul(disk, mask(lambda d: d.rectangle(P(0, sea_top) + P(1024, 1024), fill=255)))
    base = paint(base, AZURE, sea)
    waves = Image.new("L", (S, S), 0)
    wd = ImageDraw.Draw(waves)
    # 平水：同相的平行水线（中国水纹）
    period, amp = 120, 10
    x_start = cx - R - 40
    def wave_y(x, y0):
        return y0 + amp * math.sin((x - x_start) / period * 2 * math.pi)
    for row in range(4):
        y0 = sea_top + 34 + row * 28
        pts = [P(x, wave_y(x, y0)) for x in range(x_start, cx + R + 41, 3)]
        wd.line(pts, fill=255, width=(6 if row == 0 else 5) * K, joint="curve")
    # 浪沫：海面一道粗浪线，盖住山脚
    crest_y = lambda x: sea_top + 4 + 7 * math.sin((x - x_start) / 60 * 2 * math.pi)
    crest = [P(x, crest_y(x)) for x in range(x_start, cx + R + 41, 3)]
    base = paint(base, AZURE, mul(disk, mask(lambda d: d.polygon(crest + [P(cx + R + 40, sea_top + 40), P(x_start, sea_top + 40)], fill=255))))
    wd.line(crest, fill=255, width=8 * K, joint="curve")
    base = paint(base, FOAM, mul(disk, waves))
    # 立水：底部斜向条纹，石青深浅相间
    liw_top = sea_top + 150
    stripes = Image.new("L", (S, S), 0)
    sd = ImageDraw.Draw(stripes)
    for i in range(-30, 30):
        x0 = cx + i * 34
        sd.polygon([P(x0, liw_top), P(x0 + 17, liw_top), P(x0 + 17 + 120, liw_top + 260), P(x0 + 120, liw_top + 260)], fill=255)
    band = mul(sea, mask(lambda d: d.rectangle(P(0, liw_top) + P(1024, 1024), fill=255)))
    base = paint(base, AZURE_DEEP, band)
    base = paint(base, AZURE_LIGHT, mul(band, stripes))
    base = paint(base, FOAM, mul(disk, mask(lambda d: d.line([P(cx - R, liw_top), P(cx + R, liw_top)], fill=255, width=5 * K))))

    # 圆框：泥金环，主峰冲出的地方断开
    ring = mask(lambda dd: dd.ellipse(P(cx - R, cy - R) + P(cx + R, cy + R), outline=255, width=8 * K))
    ring = ImageChops.subtract(ring, mountains.filter(ImageFilter.MaxFilter(3 * K + 1)))
    base = paint(base, GOLD, ring)
    return base.resize((1024, 1024), Image.LANCZOS)


def review(im, out_dir):
    sheet = Image.new("RGB", (1300, 560), (255, 255, 255))
    big = im.resize((512, 512), Image.LANCZOS)
    sheet.paste(big, (20, 24), big)
    for bg, x0 in [((246, 246, 248), 560), ((40, 40, 46), 930)]:
        ImageDraw.Draw(sheet).rectangle((x0, 24, x0 + 340, 536), fill=bg)
        for j, sz in enumerate([128, 64, 32, 16]):
            sm = im.resize((sz, sz), Image.LANCZOS)
            sheet.paste(sm, (x0 + 20 + (j % 2) * 160, 40 + (j // 2) * 200), sm)
    sheet.save(out_dir / "review.png")


if __name__ == "__main__":
    im = build()
    im.save(sys.argv[1])
    if len(sys.argv) > 2:
        review(im, Path(sys.argv[2]))
