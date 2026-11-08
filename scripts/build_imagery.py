"""两张 16K 底图 → GPU 压缩纹理（BC1，带 mipmap），App 直接上传显存不再解码。

physical：Sentinel-2 无云影像 2020（EOX，z6 瓦片拼接，Web 墨卡托 → 等经纬），极区 85° 以外用 NE1 补
political：build_geo.py 生成的 political_16k.png

署名：Sentinel-2 cloudless - https://s2maps.eu by EOX IT Services GmbH
（Contains modified Copernicus Sentinel data 2020），CC BY-NC-SA 4.0，仅个人非商业使用。
"""
import subprocess, sys
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw, ImageFilter

Image.MAX_IMAGE_PIXELS = None
ROOT = Path(__file__).resolve().parent.parent
RAW = ROOT / "data/raw"
WORK = ROOT / "data/work"
OUT = ROOT / "Shanhai/Resources/Geo"
TC = "/Applications/Xcode.app/Contents/Developer/usr/bin/TextureConverter"
W, H = 16384, 8192
Z, N = 6, 64           # z6：64×64 张 256 像素瓦片 = 16384² 墨卡托


def stitch_mercator():
    """返回 (影像, 有效掩膜)。EOX 无数据处给的是 1 位 PNG，算无效"""
    merc = np.zeros((N * 256, N * 256, 3), dtype=np.uint8)
    valid = np.zeros((N, N), dtype=bool)
    for x in range(N):
        for y in range(N):
            p = RAW / "s2z6" / f"{x}_{y}.jpg"
            try:
                im = Image.open(p)
                if im.format != "JPEG":
                    continue
                merc[y * 256:(y + 1) * 256, x * 256:(x + 1) * 256] = np.array(im.convert("RGB"))
                valid[y, x] = True
            except Exception:
                pass
    print("invalid tiles", int((~valid).sum()), file=sys.stderr)
    return merc, valid


OCEAN = np.array([14, 27, 48], dtype=np.float32)    # Sentinel-2 深海颜色（太平洋取样）


def ne1_filler():
    """NE1 底图，水面换成卫星图的深海色，陆地与冰原保留"""
    ne = np.array(Image.open(RAW / "NE1/NE1_HR_LC_SR_W.tif").convert("RGB").resize((W, H), Image.BILINEAR)).astype(np.float32)
    r, g, b = ne[..., 0], ne[..., 1], ne[..., 2]
    water = (b > r + 55) & (b > 170) & (r < 150)
    ne[water] = OCEAN
    return ne.astype(np.uint8)


def to_equirect(merc_valid):
    merc, valid = merc_valid
    size = merc.shape[0]
    out = np.zeros((H, W, 3), dtype=np.uint8)
    lat = 90 - (np.arange(H) + 0.5) / H * 180
    limit = 85.0511
    latc = np.clip(lat, -limit, limit)
    my = (1 - np.log(np.tan(np.pi / 4 + np.radians(latc) / 2)) / np.pi) / 2 * size - 0.5
    y0 = np.clip(np.floor(my).astype(int), 0, size - 1)
    y1 = np.clip(y0 + 1, 0, size - 1)
    f = (my - y0)[:, None, None]
    xs = ((np.arange(W) + 0.5) / W * size).astype(int)          # 宽度一致，列直接对应
    for i in range(H):
        a = merc[y0[i], xs].astype(np.float32)
        b = merc[y1[i], xs].astype(np.float32)
        out[i] = (a * (1 - f[i, 0, 0]) + b * f[i, 0, 0]).astype(np.uint8)
    # 无数据瓦片与极区（85° 以外）用改色后的 NE1 补；极区在 83°–85° 间渐变
    ne = ne1_filler()
    tile_row = np.clip((my + 0.5).astype(int) // 256, 0, N - 1)
    tile_col = xs // 256
    bad = ~valid[tile_row[:, None], tile_col[None, :]]
    out[bad] = ne[bad]          # 先硬填，补洞内部绝不留黑
    # 补洞处羽化：先模糊再放大，补洞内部仍是 1，边缘约 40 像素渐变，看不出瓦片方块
    m = Image.fromarray((bad * 255).astype(np.uint8)).filter(ImageFilter.GaussianBlur(40))
    m = np.clip(np.asarray(m, dtype=np.float32) / 255 * 2, 0, 1)
    t = np.clip((np.abs(lat) - 83) / 2, 0, 1)[:, None]
    m = np.maximum(m, t)[..., None]
    rows = np.where(m.max(axis=(1, 2)) > 0)[0]
    out[rows] = (out[rows] * (1 - m[rows]) + ne[rows] * m[rows]).astype(np.uint8)
    return out


def compress(src, dst):
    subprocess.run([TC, "--compression_format=BC1", "--file_format=KTX", "--max_mipmaps=15", "--mipmap_filter=Box",
                    "--wrap_mode=Repeat", f"--output={dst}", str(src)], check=True)


# 复古地球仪配色（参照焦糖皮面地球仪）
V_OCEAN = (203, 142, 88)
V_LAND = (132, 78, 47)
V_LINE = (232, 188, 136)


def vintage():
    """复古底图：焦糖海、深棕陆地、海岸外几圈水纹线、经纬网、皮面细纹"""
    pol = np.asarray(Image.open(WORK / "political_16k.png").convert("RGB"))
    land = ~((pol[..., 0] == 0xAA) & (pol[..., 1] == 0xD3) & (pol[..., 2] == 0xEC))
    del pol
    land_img = Image.fromarray((land * 255).astype(np.uint8))

    # 海岸外的水纹：在 8K 上模糊陆地掩膜，取几条等值线，再放大回 16K
    small = land_img.resize((8192, 4096), Image.BILINEAR)
    rings = np.zeros((4096, 8192), dtype=np.float32)
    for radius, t, w in [(5, 0.30, 0.035), (12, 0.16, 0.022), (22, 0.10, 0.015)]:
        b = np.asarray(small.filter(ImageFilter.GaussianBlur(radius)), dtype=np.float32) / 255
        rings = np.maximum(rings, np.clip(1 - np.abs(b - t) / w, 0, 1))
    rings_big = np.asarray(Image.fromarray((rings * 255).astype(np.uint8)).resize((W, H), Image.BILINEAR), dtype=np.float32) / 255
    rings_big[land] = 0

    # 皮面细纹：几层随机噪声叠加
    rnd = np.random.default_rng(3)
    grain = np.zeros((H, W), dtype=np.float32)
    for size, amp in [(256, 7), (1024, 5), (4096, 3)]:
        n = rnd.standard_normal((size // 2, size)).astype(np.float32)
        grain += np.asarray(Image.fromarray(((n * 40) + 128).clip(0, 255).astype(np.uint8)).resize((W, H), Image.BICUBIC), dtype=np.float32) / 40 * amp / 3.2 - 128 / 40 * amp / 3.2

    out = np.empty((H, W, 3), dtype=np.float32)
    out[:] = V_OCEAN
    out[land] = V_LAND
    out += grain[..., None]
    out = out * (1 - rings_big[..., None] * 0.45) + np.array(V_LINE, np.float32) * rings_big[..., None] * 0.45
    del rings_big

    # 海岸线：陆地边缘一圈浅色细线
    edge = np.asarray(land_img.filter(ImageFilter.MaxFilter(5)), dtype=bool) & ~land
    out[edge] = out[edge] * 0.3 + np.array(V_LINE, np.float32) * 0.7

    # 经纬网：每 10°；赤道、回归线、极圈加粗
    grid = Image.new("L", (W, H), 0)
    gd = ImageDraw.Draw(grid)
    for lon in range(-180, 181, 10):
        x = (lon + 180) / 360 * W
        gd.line((x, 0, x, H), fill=150, width=3)
    for lat in range(-80, 81, 10):
        y = (90 - lat) / 180 * H
        gd.line((0, y, W, y), fill=150, width=3)
    for lat in (0, 23.44, -23.44, 66.56, -66.56):
        y = (90 - lat) / 180 * H
        for x0 in range(0, W, 48):
            gd.line((x0, y, x0 + 30, y), fill=230, width=6 if lat == 0 else 4)
    g = np.asarray(grid, dtype=np.float32)[..., None] / 255 * 0.55
    out = out * (1 - g) + np.array(V_LINE, np.float32) * g
    png = WORK / "vintage_16k.png"
    Image.fromarray(out.clip(0, 255).astype(np.uint8)).save(png, compress_level=1)
    compress(png, OUT / "vintage.ktx")


def main():
    WORK.mkdir(exist_ok=True)
    what = sys.argv[1:] or ["physical", "political", "vintage"]
    if "physical" in what:
        eq = to_equirect(stitch_mercator())
        png = WORK / "physical_16k.png"
        Image.fromarray(eq).save(png, compress_level=1)
        compress(png, OUT / "physical.ktx")
    if "political" in what:
        compress(WORK / "political_16k.png", OUT / "political.ktx")
    if "vintage" in what:
        vintage()


if __name__ == "__main__":
    main()
