#!/bin/sh
# 下载构建离线数据要用的原始数据到 data/raw/（约 2 GB，卫星瓦片占大头）。已下载的文件会跳过。
# 用法：scripts/fetch_raw.sh [geo|imagery|climate|all]，默认 all
set -e
cd "$(dirname "$0")/.."
RAW=data/raw
mkdir -p "$RAW"
what=${1:-all}

ne() {   # Natural Earth 10m：$1 分类 $2 名称 $3 解压目录
  [ -d "$RAW/$3" ] && return
  curl -fsSL -o "$RAW/$2.zip" "https://naciscdn.org/naturalearth/10m/$1/$2.zip"
  mkdir -p "$RAW/$3" && unzip -qo "$RAW/$2.zip" -d "$RAW/$3"
}

tiles() {   # $1 目录 $2 缩放级 $3 URL 模板（{x} {y}）$4 扩展名
  mkdir -p "$RAW/$1"
  n=$((1 << $2)); x=0
  while [ $x -lt $n ]; do
    y=0
    while [ $y -lt $n ]; do
      f="$RAW/$1/${x}_${y}.$4"
      [ -s "$f" ] || echo "$(echo "$3" | sed "s/{x}/$x/;s/{y}/$y/") $f"
      y=$((y + 1))
    done
    x=$((x + 1))
  done | xargs -P 16 -n 2 sh -c 'curl -fsSL --retry 3 -o "$1" "$0" || echo "失败 $0" >&2'
}

if [ "$what" = geo ] || [ "$what" = all ]; then
  ne cultural ne_10m_admin_0_countries_chn ne_10m_admin_0_countries_chn
  ne cultural ne_10m_admin_1_states_provinces ne_10m_admin_1_states_provinces
  ne cultural ne_10m_populated_places ne_10m_populated_places
  ne physical ne_10m_geography_marine_polys marine
  # 高程：AWS Terrain Tiles（terrarium 编码）z5，32×32 张
  tiles terrarium5 5 "https://s3.amazonaws.com/elevation-tiles-prod/terrarium/5/{x}/{y}.png" png
fi

if [ "$what" = imagery ] || [ "$what" = all ]; then
  ne raster NE1_HR_LC_SR_W NE1
  # 卫星影像：EOX Sentinel-2 cloudless 2020，z6，64×64 张。CC BY-NC-SA 4.0，仅限非商业使用
  tiles s2z6 6 "https://tiles.maps.eox.at/wmts/1.0.0/s2cloudless-2020_3857/default/g/6/{y}/{x}.jpg" jpg
fi

if [ "$what" = climate ] || [ "$what" = all ]; then
  mkdir -p "$RAW/climate"
  for f in ncep.reanalysis.derived/surface_gauss/uwnd.10m.mon.ltm.1991-2020.nc \
           ncep.reanalysis.derived/surface_gauss/vwnd.10m.mon.ltm.1991-2020.nc \
           gpcp/precip.mon.ltm.1991-2020.nc; do
    out="$RAW/climate/$(basename "$f")"
    [ -s "$out" ] || curl -fsSL -o "$out" "https://downloads.psl.noaa.gov/Datasets/$f"
  done
fi
echo "原始数据就绪：$RAW"
