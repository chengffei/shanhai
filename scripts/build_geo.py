"""把 Natural Earth 矢量与栅格加工成 App 用的离线地理数据。

输出到 Shanhai/Resources/Geo/：
  countries.json  regions.json   国家与省级区划元数据
  ids.bin         zlib(raw deflate)：W*H 个 uint16 省级 ID，后接 W*H 个 uint8 国家 ID
  borders.bin     线框：float32 (lon,lat) 顶点 + uint32 索引（0xFFFFFFFF 断开）
  political_16k.png（data/work）普通视图底图，build_imagery.py 压成 political.ktx
  height.bin      zlib：HW*HH 个 int16 海拔（米）

国界口径：Natural Earth 中国视角（admin_0_countries_chn）。台湾、香港、澳门作为中国的省级区。
争议地区内省级区与国家归属不一致的像素，只保留国家，不算省。
"""
import json, struct, sys, zlib
from collections import Counter
from pathlib import Path

import numpy as np
import shapefile
from PIL import Image, ImageDraw
from shapely.geometry import shape, MultiPolygon, Polygon
from shapely.ops import unary_union

Image.MAX_IMAGE_PIXELS = None
ROOT = Path(__file__).resolve().parent.parent
RAW = ROOT / "data/raw"
OUT = ROOT / "Shanhai/Resources/Geo"
OUT.mkdir(parents=True, exist_ok=True)

W, H = 8192, 4096          # ID 图与底图
HW, HH = 4096, 2048        # 高程图
MERGE = {"TWN": ("台湾省", "Taiwan", "Q57251"), "HKG": ("香港特别行政区", "Hong Kong", "Q8646"),
         "MAC": ("澳门特别行政区", "Macau", "Q14773")}
PALETTE = ["#F1E4C3", "#DCEACB", "#F4D8CC", "#E6DCF0", "#F5EAB2", "#D3E8DE", "#EFD6E2"]
OCEAN = "#AAD3EC"
ANTARCTICA = "#F4F6F8"
DISSOLVE = {"IN-AR": "CN-XZ"}   # 藏南并入西藏
# Natural Earth 里这几国的 admin-1 比「省 / 州」细一级，按一级行政区合并（字段, {名称: (Wikidata, 中文名)}）
GROUP_BY = {
    "FRA": ("region", {
        "Auvergne-Rhône-Alpes": ("Q18338206", "奥弗涅-罗讷-阿尔卑斯大区"), "Bourgogne-Franche-Comté": ("Q18578267", "勃艮第-弗朗什-孔泰大区"),
        "Bretagne": ("Q12130", "布列塔尼大区"), "Centre-Val de Loire": ("Q13947", "中央-卢瓦尔河谷大区"), "Corse": ("Q14112", "科西嘉"),
        "Grand Est": ("Q18677983", "大东部大区"), "Guadeloupe": ("Q17012", "瓜德罗普"), "Guyane française": ("Q3769", "法属圭亚那"),
        "Hauts-de-France": ("Q18677767", "上法兰西大区"), "Martinique": ("Q17054", "马提尼克"), "Mayotte": ("Q17063", "马约特"),
        "Normandie": ("Q18677875", "诺曼底大区"), "Nouvelle-Aquitaine": ("Q18678082", "新阿基坦大区"), "Occitanie": ("Q18678265", "奥克西塔尼大区"),
        "Pays de la Loire": ("Q16994", "卢瓦尔河地区大区"), "Provence-Alpes-Côte-d'Azur": ("Q15104", "普罗旺斯-阿尔卑斯-蔚蓝海岸大区"),
        "Réunion": ("Q17070", "留尼汪"), "Île-de-France": ("Q13917", "法兰西岛大区")}),
    "ITA": ("region", {
        "Abruzzo": ("Q1284", "阿布鲁佐"), "Apulia": ("Q1447", "普利亚"), "Basilicata": ("Q1452", "巴斯利卡塔"), "Calabria": ("Q1458", "卡拉布里亚"),
        "Campania": ("Q1438", "坎帕尼亚"), "Emilia-Romagna": ("Q1263", "艾米利亚-罗马涅"), "Friuli-Venezia Giulia": ("Q1250", "弗留利-威尼斯朱利亚"),
        "Lazio": ("Q1282", "拉齐奥"), "Liguria": ("Q1256", "利古里亚"), "Lombardia": ("Q1210", "伦巴第"), "Marche": ("Q1279", "马尔凯"),
        "Molise": ("Q1443", "莫利塞"), "Piemonte": ("Q1216", "皮埃蒙特"), "Sardegna": ("Q1462", "撒丁"), "Sicily": ("Q1460", "西西里"),
        "Toscana": ("Q1273", "托斯卡纳"), "Trentino-Alto Adige": ("Q1237", "特伦蒂诺-上阿迪杰"), "Umbria": ("Q1280", "翁布里亚"),
        "Valle d'Aosta": ("Q1222", "瓦莱达奥斯塔"), "Veneto": ("Q1243", "威尼托")}),
    "ESP": ("region", {
        "Andalucía": ("Q5783", "安达卢西亚"), "Aragón": ("Q4040", "阿拉贡"), "Asturias": ("Q3934", "阿斯图里亚斯"), "Canary Is.": ("Q5813", "加那利群岛"),
        "Cantabria": ("Q3946", "坎塔布里亚"), "Castilla y León": ("Q5739", "卡斯蒂利亚-莱昂"), "Castilla-La Mancha": ("Q5748", "卡斯蒂利亚-拉曼恰"),
        "Cataluña": ("Q5705", "加泰罗尼亚"), "Ceuta": ("Q5823", "休达"), "Extremadura": ("Q5777", "埃斯特雷马杜拉"), "Foral de Navarra": ("Q4018", "纳瓦拉"),
        "Galicia": ("Q3908", "加利西亚"), "Islas Baleares": ("Q5765", "巴利阿里群岛"), "La Rioja": ("Q5727", "拉里奥哈"), "Madrid": ("Q5756", "马德里自治区"),
        "Melilla": ("Q5831", "梅利利亚"), "Murcia": ("Q5772", "穆尔西亚"), "País Vasco": ("Q3995", "巴斯克"), "Valenciana": ("Q5720", "巴伦西亚")}),
    "GBR": ("geonunit", {"England": ("Q21", "英格兰"), "Scotland": ("Q22", "苏格兰"), "Wales": ("Q25", "威尔士"), "Northern Ireland": ("Q26", "北爱尔兰")}),
}
SHORT = {"中华人民共和国": "中国", "朝鲜民主主义人民共和国": "朝鲜", "大韩民国": "韩国", "阿拉伯联合酋长国": "阿联酋",
         "澳屬印度洋領地": "澳属印度洋领地", "密克罗尼西亚联邦": "密克罗尼西亚", "波斯尼亚和黑塞哥维那": "波黑"}


def km2(g):
    """近似面积：平方度乘纬度余弦"""
    import math
    return round(sum(p.area * math.cos(math.radians(p.centroid.y)) for p in polys(g)) * 111.32 ** 2)


def polys(geom):
    if geom.is_empty:
        return []
    return list(geom.geoms) if isinstance(geom, MultiPolygon) else [geom]


def px(coords, w, h):
    return [((lon + 180) / 360 * w, (90 - lat) / 180 * h) for lon, lat in coords]


def raster(items, w, h, mode):
    """items: [(id, geom)]，大的先画，小的后画（飞地覆盖母体）。"""
    img = Image.new(mode, (w, h), 0)
    d = ImageDraw.Draw(img)
    for gid, g in sorted(items, key=lambda t: -t[1].area):
        for p in polys(g):
            d.polygon(px(p.exterior.coords, w, h), fill=gid)
    return img


def load_countries():
    r = shapefile.Reader(str(RAW / "ne_10m_admin_0_countries_chn/ne_10m_admin_0_countries_chn.shp"), encoding="utf-8")
    rows = []
    geoms = {}
    for sr in r.iterShapeRecords():
        rec = sr.record.as_dict()
        a3 = rec["ADM0_A3"]
        g = shape(sr.shape.__geo_interface__).buffer(0)
        target = "CHN" if a3 in ("HKG", "MAC") else a3
        geoms.setdefault(target, []).append(g)
        if target != a3:
            continue
        rows.append(rec)
    countries = []
    for i, rec in enumerate(sorted(rows, key=lambda x: x["NAME_ZH"] or x["NAME"]), start=1):
        a3 = rec["ADM0_A3"]
        countries.append({
            "id": i, "a3": a3, "iso2": rec["ISO_A2_EH"], "name": SHORT.get(rec["NAME_ZH"], rec["NAME_ZH"] or rec["NAME"]),
            "formal": rec["NAME_ZH"] or rec["NAME"],
            "nameEn": rec["NAME"], "wikidata": rec["WIKIDATAID"], "continent": rec["CONTINENT"],
            "subregion": rec["SUBREGION"], "pop": rec["POP_EST"], "color": rec["MAPCOLOR7"],
            "label": [round(rec["LABEL_X"], 3), round(rec["LABEL_Y"], 3)], "labelRank": rec["LABELRANK"],
            "minLabel": rec["MIN_LABEL"],
        })
    cgeom = {c["id"]: unary_union(geoms[c["a3"]]) for c in countries}
    return countries, cgeom


def load_regions():
    r = shapefile.Reader(str(RAW / "ne_10m_admin_1_states_provinces/ne_10m_admin_1_states_provinces.shp"), encoding="utf-8")
    groups = {}
    for sr in r.iterShapeRecords():
        rec = sr.record.as_dict()
        g = shape(sr.shape.__geo_interface__).buffer(0)
        a3 = rec["adm0_a3"]
        if a3 in MERGE:
            key = a3
        elif a3 in GROUP_BY and rec[GROUP_BY[a3][0]] in GROUP_BY[a3][1]:
            key = f"{a3}:{rec[GROUP_BY[a3][0]]}"
        else:
            key = rec["adm1_code"]
        groups.setdefault(key, []).append((rec, g))
    regions, rgeom = [], {}
    for i, (key, items) in enumerate(sorted(groups.items()), start=1):
        g = unary_union([x[1] for x in items])
        rec = items[0][0]
        if ":" in key:
            a3, nm = key.split(":", 1)
            qid, zh = GROUP_BY[a3][1][nm]
            lp = g.representative_point()
            meta = {"name": zh, "nameEn": nm, "wikidata": qid, "iso": "", "type": "", "label": [round(lp.x, 3), round(lp.y, 3)], "labelRank": 3}
        elif key in MERGE:
            name, en, qid = MERGE[key]
            lp = g.representative_point()
            meta = {"name": name, "nameEn": en, "wikidata": qid, "iso": "CN-" + {"TWN": "TW", "HKG": "HK", "MAC": "MO"}[key],
                    "type": "", "label": [round(lp.x, 3), round(lp.y, 3)], "labelRank": 2, "area": round(sum(x[0]["area_sqkm"] or 0 for x in items))}
        else:
            name = rec["name_zh"] or rec["name"] or rec["name_en"]
            meta = {"name": name, "nameEn": rec["name_en"] or rec["name"], "wikidata": rec["wikidataid"],
                    "iso": rec["iso_3166_2"], "type": rec["type_en"] or "",
                    "label": [round(rec["longitude"], 3), round(rec["latitude"], 3)],
                    "labelRank": rec["labelrank"], "area": rec["area_sqkm"]}
        meta["id"] = i
        meta["adm0"] = rec["adm0_a3"]
        meta["area"] = km2(g)
        regions.append(meta)
        rgeom[i] = g
    return regions, rgeom


def ring_lines(geoms, tol):
    """返回 [(owner_id, [(lon,lat),...]), ...]，简化后的外环与内环。"""
    out = []
    for gid, g in geoms.items():
        # 简化后再把长直边加密到 0.5°，免得两点间的弦线钻进球面
        for p in polys(g.simplify(tol, preserve_topology=True).segmentize(0.5)):
            for ring in [p.exterior, *p.interiors]:
                # 沿 ±180° 经线或南极点的边是切割产生的假边，不画
                piece = []
                for a, b in zip(ring.coords[:-1], ring.coords[1:]):
                    fake = (abs(a[0]) > 179.99 and abs(b[0]) > 179.99) or (a[1] < -89.9 and b[1] < -89.9)
                    if fake:
                        if len(piece) >= 2:
                            out.append((gid, piece))
                        piece = []
                        continue
                    if not piece:
                        piece = [a]
                    piece.append(b)
                if len(piece) >= 2:
                    out.append((gid, piece))
    return out


def main():
    countries, cgeom = load_countries()
    regions, rgeom = load_regions()
    print(f"{len(countries)} countries, {len(regions)} regions", file=sys.stderr)

    cimg = np.array(raster(list(cgeom.items()), W, H, "L"), dtype=np.uint8)
    rimg = np.array(raster(list(rgeom.items()), W, H, "I"), dtype=np.int32)

    # 省 → 国：省内像素的国家众数
    flat_r, flat_c = rimg.ravel(), cimg.ravel()
    mask = (flat_r > 0) & (flat_c > 0)
    pairs = Counter(zip(flat_r[mask].tolist(), flat_c[mask].tolist()))
    best = {}
    for (rid, cid), n in pairs.items():
        if n > best.get(rid, (0, 0))[1]:
            best[rid] = (cid, n)
    a3_to_id = {c["a3"]: c["id"] for c in countries}
    totals = Counter(flat_r[mask].tolist())
    remap = np.arange(len(regions) + 1, dtype=np.int32)
    by_iso = {r["iso"]: r["id"] for r in regions}
    for reg in regions:
        own = a3_to_id.get("CHN" if reg["adm0"] in MERGE else reg["adm0"], 0)
        cid, n = best.get(reg["id"], (own, 0))
        # 只有大部分像素落在别国（中国视角）时才改归属，避免边境小区被栅格误差带走
        if own == 0 or (cid != own and n > 200 and n / totals[reg["id"]] > 0.6):
            print(f"country: {reg['name']} → {next(c['name'] for c in countries if c['id'] == cid)}", file=sys.stderr)
        else:
            cid = own
        reg["country"] = cid
    # 中国视角下不存在的省级区：并入所属省
    for iso, host in DISSOLVE.items():
        if iso in by_iso and host in by_iso:
            remap[by_iso[iso]] = by_iso[host]
    rimg = remap[rimg]
    for reg in regions:
        reg.pop("adm0")
    rc = np.zeros(len(regions) + 1, dtype=np.uint8)
    for reg in regions:
        rc[reg["id"]] = reg["country"]
    # 争议地区：省的归属国与该像素的国家不一致 → 不算省
    rimg[(rimg > 0) & (rc[rimg] != cimg)] = 0
    rimg[cimg == 0] = 0
    counts = np.bincount(rimg.ravel(), minlength=len(regions) + 1)
    for reg in regions:
        reg["pixels"] = int(counts[reg["id"]])
    print(f"regions without pixels: {sum(1 for r in regions if r['pixels'] == 0)}", file=sys.stderr)

    raw = rimg.astype("<u2").tobytes() + cimg.tobytes()
    co = zlib.compressobj(9, zlib.DEFLATED, -15)
    (OUT / "ids.bin").write_bytes(struct.pack("<II", W, H) + co.compress(raw) + co.flush())

    # 边界线：国界（含海岸线）与省界
    verts, idx = [], []
    def emit(lines):
        start = len(idx)
        ranges = {}
        for owner, cs in lines:
            s = len(idx)
            base = len(verts)
            verts.extend(cs)
            idx.extend(range(base, base + len(cs)))
            idx.append(0xFFFFFFFF)
            r0 = ranges.setdefault(owner, [])
            r0.append([s, len(idx) - s])
        return [start, len(idx) - start], ranges
    country_range, c_ranges = emit(ring_lines(cgeom, 0.004))
    region_range, r_ranges = emit(ring_lines({k: g for k, g in rgeom.items() if remap[k] == k}, 0.008))
    for c in countries:
        c["outline"] = c_ranges.get(c["id"], [])
    for reg in regions:
        reg["outline"] = r_ranges.get(reg["id"], [])
    v = np.array(verts, dtype="<f4")
    i = np.array(idx, dtype="<u4")
    (OUT / "borders.bin").write_bytes(struct.pack("<IIIIII", len(v), len(i), *country_range, *region_range) + v.tobytes() + i.tobytes())
    print(f"border verts {len(v)}, indices {len(i)}", file=sys.stderr)

    for c in countries:
        c["bbox"] = [round(x, 3) for x in cgeom[c["id"]].bounds]
        c["area"] = km2(cgeom[c["id"]])
    for reg in regions:
        reg["bbox"] = [round(x, 3) for x in rgeom[reg["id"]].bounds]
    (OUT / "countries.json").write_text(json.dumps(countries, ensure_ascii=False, separators=(",", ":")))
    (OUT / "regions.json").write_text(json.dumps(regions, ensure_ascii=False, separators=(",", ":")))

    # 普通视图底图：2 倍分辨率画再缩小，边缘抗锯齿
    big = Image.new("RGB", (W * 2, H * 2), OCEAN)
    d = ImageDraw.Draw(big)
    for c in sorted(countries, key=lambda c: -cgeom[c["id"]].area):
        fill = ANTARCTICA if c["a3"] == "ATA" else PALETTE[(c["color"] - 1) % len(PALETTE)]
        for p in polys(cgeom[c["id"]]):
            d.polygon(px(p.exterior.coords, W * 2, H * 2), fill=fill)
            for hole in p.interiors:
                d.polygon(px(hole.coords, W * 2, H * 2), fill=OCEAN)
    (ROOT / "data/work").mkdir(exist_ok=True)
    big.save(ROOT / "data/work/political_16k.png", compress_level=1)   # build_imagery.py 压成 political.ktx

    build_cities(countries)
    build_marine()
    build_height()


def build_marine():
    """海洋、海、湾、海峡名：标签点取多边形内部点，名称转简体"""
    from opencc import OpenCC
    t2s = OpenCC("t2s").convert
    r = shapefile.Reader(str(RAW / "marine/ne_10m_geography_marine_polys.shp"), encoding="utf-8")
    out = []
    for sr in r.iterShapeRecords():
        rec = sr.record.as_dict()
        name = t2s(rec["name_zh"] or "")
        if not name or rec["featurecla"] in ("river", "reef", "lagoon", "inlet"):
            continue
        g = shape(sr.shape.__geo_interface__).buffer(0)
        pt = max(polys(g), key=lambda p: p.area).representative_point()
        out.append({"name": name, "lon": round(pt.x, 3), "lat": round(pt.y, 3), "kind": rec["featurecla"],
                    "minLabel": rec["min_label"], "rank": rec["scalerank"], "area": round(km2(g))})
    out.sort(key=lambda m: (m["rank"], -m["area"]))
    (OUT / "marine.json").write_text(json.dumps(out, ensure_ascii=False, separators=(",", ":")))
    print(f"{len(out)} marine labels", file=sys.stderr)


def build_cities(countries):
    r = shapefile.Reader(str(RAW / "ne_10m_populated_places/ne_10m_populated_places.shp"), encoding="utf-8")
    out = []
    for rec in r.records():
        cla = rec["FEATURECLA"]
        if cla in ("Scientific station", "Historic place", "Meteorological Station"):
            continue
        cap = 2 if cla.startswith("Admin-0 capital") else 1 if cla.startswith("Admin-1") else 0
        if rec["ADM0_A3"] == "TWN" and cap == 2:
            cap = 1          # 中国视角：台北为省会
        out.append({"name": rec["NAME_ZH"] or rec["NAME"], "lon": round(rec["LONGITUDE"], 4), "lat": round(rec["LATITUDE"], 4),
                    "minZoom": rec["MIN_ZOOM"], "pop": rec["POP_MAX"], "cap": cap, "wikidata": rec["WIKIDATAID"]})
    out.sort(key=lambda c: (c["minZoom"], -c["cap"], -c["pop"]))
    (OUT / "cities.json").write_text(json.dumps(out, ensure_ascii=False, separators=(",", ":")))
    print(f"{len(out)} cities", file=sys.stderr)


def build_height():
    """terrarium z4（Web 墨卡托 4096²）→ 等经纬 4096×2048 int16。"""
    tiles = RAW / "terrarium4"
    merc = np.zeros((4096, 4096), dtype=np.float32)
    for x in range(16):
        for y in range(16):
            a = np.array(Image.open(tiles / f"{x}_{y}.png").convert("RGB"), dtype=np.float32)
            merc[y * 256:(y + 1) * 256, x * 256:(x + 1) * 256] = a[..., 0] * 256 + a[..., 1] + a[..., 2] / 256 - 32768
    lat = 90 - (np.arange(HH) + 0.5) / HH * 180
    latc = np.clip(lat, -85.05, 85.05)
    my = (1 - np.log(np.tan(np.pi / 4 + np.radians(latc) / 2)) / np.pi) / 2 * 4096
    mx = (np.arange(HW) + 0.5) / HW * 4096
    yi = np.clip(my.astype(int), 0, 4095)
    xi = np.clip(mx.astype(int), 0, 4095)
    eq = merc[yi[:, None], xi[None, :]]
    eq[lat > 85.05] = merc[0].mean()
    eq[lat < -85.05] = 2800  # 南极高原
    co = zlib.compressobj(9, zlib.DEFLATED, -15)
    (OUT / "height.bin").write_bytes(struct.pack("<II", HW, HH) + co.compress(np.clip(eq, -11000, 9000).astype("<i2").tobytes()) + co.flush())


if __name__ == "__main__":
    main()
