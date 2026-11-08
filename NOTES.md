# 山海 NOTES

11-08 由 Meridian 改名为山海（取自《山海经》），目录 personal/shanhai，Bundle ID io.github.chengffei.shanhai，装为 /Applications/山海.app。

原生 macOS 地球仪，做给妻子（对地理零基础但有兴趣）。2026-11-08 建。自用，不开源，不发版，不占 WIP。

## 现状（0.1.0）

- 自写 Metal 地球：两种视图。普通是按国家上色的政区图；地形是 Sentinel-2 卫星影像，加 3 倍夸张的真实起伏。
- 点击选中省级区（4468 个），点国家名切到整国；悬停时左下角显示地名。
- 标签分国家、省级区、城市（7295 个），按缩放显示，互不重叠。
- 右侧面板：基本资料、简介、风土人情、历史、大事、名人。内容来自中文维基和 Wikidata，离线打包。
- 搜索国家、省份、城市，选中后飞过去；右下角有回到全球、3D、指北、缩放按钮。

## 为什么不用 MapKit（11-08 实测）

国区账号下 MapKit 地图由高德提供：

- 3D 地球和普通视图的地形可用；
- `.imagery(elevation: .realistic)` 近景全是灰块；
- `.hybrid` 的 3D 卫星图只覆盖中国境内，境外灰块或很糊。

所以「真实地形」做不了，改为自己渲染，数据全离线。

## 数据管线

全部在 `scripts/`，Python 环境在 `scripts/.venv`（numpy、pillow、pyshp、shapely、requests）。原始数据在 `data/raw/`，中间产物在 `data/work/`，都不入 git。

| 脚本 | 产物 |
|---|---|
| build_geo.py | 国家、省、城市元数据，ID 栅格，边界线，高程 |
| build_imagery.py | political.ktx、physical.ktx（16K BC1） |
| build_content.py | Content/<国家a3>.json |

- 国界口径：Natural Earth 中国视角（admin_0_countries_chn）。台湾、香港、澳门是中国的省级区；藏南并入西藏（`DISSOLVE`）；其他争议区按多数像素所在国归属。
- 法、意、西、英的 admin-1 比省级细一级，按大区、自治区、构成国合并（`GROUP_BY`，Wikidata ID 已逐个核对）。
- ID 栅格 8192×4096：uint16 省 + uint8 国。CPU 点选和 GPU 高亮共用一块共享内存。
- 高程：AWS terrarium z4 瓦片，转成等经纬 4096×2048。
- 卫星影像：EOX Sentinel-2 cloudless 2020，z6 瓦片。**CC BY-NC-SA 4.0，只能非商业使用**，面板底部要署名。
- 内容：名人走 QLever 的 Wikidata 镜像（官方 WDQS 这类全库查询必超时），取语言版本数 ≥20 的人，按出生地或工作地坐标落进 ID 栅格；事件取有坐标的 occurrence。

## 性能（11-08，M1 Pro，Release，2560×1640）

- 自转时 GPU 每帧 4 到 5 ms，60 Hz 外接屏跑满。
- 按需绘制：静止时不出帧，空闲 CPU 0%。
- 内存 446 MB，两张 16K 底图常驻。做过两处压缩：
  - 底图改 BC1 KTX：省掉 JPG 解码，少约 150 MB；
  - MSAA 颜色和深度改 memoryless：少约 130 MB。
- 标签按需排进 16 MB 图集，满了清空重排；碰撞检测用网格。

## 命令

- `xcodegen generate` 后构建；`scripts/install.sh` 装 Release 到 /Applications。
- 着色器在 `Shanhai/Resources/Shaders.msl`，运行时编译。本机 Xcode 没装 Metal 工具链，不依赖它。
- 截图调试：`open -n --env SHANHAI_PRINT_WINDOW=1 --env SHANHAI_CAMERA=纬,经,高度,倾斜,朝向 ...`，另有 `SHANHAI_MODE=terrain`、`SHANHAI_SELECT=纬,经`、`SHANHAI_HOVER=纬,经`、`SHANHAI_NOLABELS=1`。**直接执行二进制不出窗口**（沙盒应用），要用 `open`。
- 图标：`design/icon_shanhai.py` 程序绘制，`scripts/generate-icon.sh` 一步生成 icns。构图是海水江崖：团扇圆框里，青绿主峰从水纹中升起、冲出圆框，配朱日；山顶石青晕染到山脚石绿，不放文字。Felix 否掉过两轮：渲染地球四版太普通，罗盘、青绿、舆图三版是剪贴画。
- 离屏渲染地球：`SHANHAI_ICON=容器内路径.png`（沙盒只能写 `~/Library/Containers/io.github.chengffei.shanhai/Data/tmp`）。

## 待做

- 内容是维基原文，对零基础偏难。可以用 Claude 改写成大白话卡片。
- 地形近景受 16K 纹理限制（约 2.4 km/像素）。再清楚要做分块流式加载。
- 地形网格 1024×512，近看山体偏粗。可以按视野做 LOD。
