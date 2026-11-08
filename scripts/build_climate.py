"""季风模拟数据：逐月气候平均的地面风、降水、季风区、雨带中心线。

来源（都是公开的 NOAA PSL 数据，1991–2020 气候平均）：
- 地面 10 m 风：NCEP/NCAR 再分析 uwnd/vwnd.10m.mon.ltm（T62 高斯网格）
- 降水：GPCP v2.3 precip.mon.ltm（2.5°）

输出 Shanhai/Resources/Geo/climate.bin：
  头 16 字节：b"SHCL", uint32 宽 360, 高 180, 月 12
  12×180×360×4 个 float16：u 东向风 m/s、v 北向风 m/s、降水 mm/天、季风区指数（≥1 为季风区）
    行优先，(0,0) 在西北角，格心 lon = -179.5 + i，lat = 89.5 - j
  12×361 个 float32：每月每条经线上雨带中心的纬度（第 361 个 = 第 1 个，闭合用）
"""
import struct
from pathlib import Path

import netCDF4 as nc
import numpy as np

ROOT = Path(__file__).resolve().parent.parent
RAW = ROOT / "data/raw/climate"
OUT = ROOT / "Shanhai/Resources/Geo/climate.bin"

W, H = 360, 180
LON = -179.5 + np.arange(W)
LAT = 89.5 - np.arange(H)


def regrid(field, lat, lon):
    """(12, nlat, nlon) → (12, H, W)，经度周期、纬度线性插值"""
    order = np.argsort(lat)
    lat, field = lat[order], field[:, order, :]
    lon = np.asarray(lon) % 360
    ext_lon = np.concatenate([lon - 360, lon, lon + 360])
    out = np.empty((12, H, W), np.float32)
    tgt_lon = LON % 360
    for m in range(12):
        f = field[m]
        f3 = np.concatenate([f, f, f], axis=1)
        cols = np.stack([np.interp(tgt_lon, ext_lon, f3[j]) for j in range(f.shape[0])])   # (nlat, W)
        out[m] = np.stack([np.interp(LAT, lat, cols[:, i]) for i in range(W)], axis=1)
    return out


def box(a, r, axis_wrap=True):
    """沿经度（周期）和纬度做 (2r+1) 宽的均值平滑"""
    k = 2 * r + 1
    s = sum(np.roll(a, d, axis=-1) for d in range(-r, r + 1)) / k
    pad = np.pad(s, [(0, 0)] * (a.ndim - 2) + [(r, r), (0, 0)], mode="edge")
    return sum(pad[..., r + d:r + d + a.shape[-2], :] for d in range(-r, r + 1)) / k


def main():
    def load(name, var):
        d = nc.Dataset(RAW / name)
        return np.array(d.variables[var][:], np.float32), np.array(d.variables["lat"][:]), np.array(d.variables["lon"][:])

    u, lat, lon = load("uwnd.10m.mon.ltm.1991-2020.nc", "uwnd")
    v, _, _ = load("vwnd.10m.mon.ltm.1991-2020.nc", "vwnd")
    p, plat, plon = load("precip.mon.ltm.1991-2020.nc", "precip")
    U, V = regrid(u, lat, lon), regrid(v, lat, lon)
    P = np.clip(regrid(p, plat, plon), 0, None)

    # 季风区（Wang & Ding 2008）：当地夏季（北半球 5–9 月，南半球 11–3 月）比冬季多 2.5 mm/天，
    # 且夏季 5 个月降水占全年 55% 以上。指数 = 两个比值取小，≥1 即季风区
    mjjas = P[4:9].mean(0)
    ndjfm = P[[10, 11, 0, 1, 2]].mean(0)
    nh = (LAT >= 0)[:, None]
    summer = np.where(nh, mjjas, ndjfm)
    winter = np.where(nh, ndjfm, mjjas)
    annual = P.mean(0) * 12
    rng = summer - winter
    ratio = summer * 5 / np.maximum(annual, 1e-3)
    mon = np.minimum(rng / 2.5, ratio / 0.55)
    mon = np.where(np.abs(LAT)[:, None] > 45, 0, mon)
    mon = box(box(mon, 2), 2)
    print("monsoon area share (|lat|<45):", float((mon >= 1).mean()))

    # 雨带中心：每月在 25°S–30°N 内沿经度找一条连续路径，让路径上的降水最多（Viterbi，纬度跳一格扣分）；
    # 逐经线取最大值会在两条雨带之间来回跳
    Ps = box(P, 3)
    idx = np.where((LAT >= -25) & (LAT <= 30))[0]
    lats = LAT[idx]
    nb = len(idx)
    jump = np.abs(np.arange(nb)[:, None] - np.arange(nb)[None, :]) * 1.5
    itcz = np.empty((12, W), np.float32)
    for m in range(12):
        sub = np.tile(Ps[m][idx], 3)                     # 绕地球三圈，取中间一圈，消掉起点影响
        score = sub[:, 0].copy()
        back = np.zeros((nb, sub.shape[1]), int)
        for i in range(1, sub.shape[1]):
            cand = score[None, :] - jump                  # [到, 从]
            back[:, i] = cand.argmax(1)
            score = cand.max(1) + sub[:, i]
        path = np.empty(sub.shape[1], int)
        path[-1] = score.argmax()
        for i in range(sub.shape[1] - 1, 0, -1):
            path[i - 1] = back[path[i], i]
        itcz[m] = lats[path[W:2 * W]]
    for _ in range(3):
        itcz = sum(np.roll(itcz, d, axis=1) for d in range(-5, 6)) / 11
    itcz = np.concatenate([itcz, itcz[:, :1]], axis=1)
    for m in (0, 6):
        print("month", m + 1, "itcz at 80E/0E/150W:", itcz[m, 260], itcz[m, 180], itcz[m, 30])

    tex = np.stack([U, V, P, np.broadcast_to(mon, P.shape)], axis=-1).astype(np.float16)   # (12, H, W, 4)
    with open(OUT, "wb") as f:
        f.write(b"SHCL" + struct.pack("<3I", W, H, 12))
        f.write(tex.tobytes())
        f.write(itcz.astype("<f4").tobytes())
    print(OUT, OUT.stat().st_size)
    # 抽查：印度孟买附近 1 月、7 月风向
    j, i = int(89.5 - 15), int(72 + 179.5)
    print("Arabian Sea Jan u,v:", U[0, j, i], V[0, j, i], " Jul:", U[6, j, i], V[6, j, i])
    print("Mumbai precip Jan/Jul:", P[0, int(89.5 - 19), int(73 + 179.5)], P[6, int(89.5 - 19), int(73 + 179.5)])


if __name__ == "__main__":
    main()
