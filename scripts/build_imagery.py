"""两张 16K 底图 → GPU 压缩纹理（BC1，带 mipmap），App 直接上传显存不再解码。

physical：Sentinel-2 无云影像 2020（EOX，z6 瓦片拼接，Web 墨卡托 → 等经纬），极区 85° 以外用 NE1 补
political：build_geo.py 生成的 political_16k.png

署名：Sentinel-2 cloudless - https://s2maps.eu by EOX IT Services GmbH
（Contains modified Copernicus Sentinel data 2020），CC BY-NC-SA 4.0，仅个人非商业使用。
"""
import subprocess, sys
from pathlib import Path

import numpy as np
from PIL import Image, ImageFilter

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


def main():
    WORK.mkdir(exist_ok=True)
    what = sys.argv[1:] or ["physical", "political"]
    if "physical" in what:
        eq = to_equirect(stitch_mercator())
        png = WORK / "physical_16k.png"
        Image.fromarray(eq).save(png, compress_level=1)
        compress(png, OUT / "physical.ktx")
    if "political" in what:
        compress(WORK / "political_16k.png", OUT / "political.ktx")


if __name__ == "__main__":
    main()
