# 山海 NOTES

11-08 由 Meridian 改名为山海（取自《山海经》），目录 personal/shanhai，Bundle ID io.github.chengffei.shanhai，装为 /Applications/山海.app。

原生 macOS 地球仪，做给妻子（对地理零基础但有兴趣）。2026-11-08 建。自用，不开源，不发版，不占 WIP。

## 现状（0.1.0）

- 自写 Metal 地球：三种风格。普通是按国家上色的政区图；地形是 Sentinel-2 卫星影像，加 3 倍夸张的真实起伏；复古是焦糖皮面地球仪（11-08 加）。
- 复古风格（11-08 去掉了黄铜环，Felix 嫌挡视线）包括：焦糖海、深棕陆地、海岸外水纹线、经纬网，暖灰桌面背景；奶油色字配深棕描边；暖金高亮。底图第一次切到复古时才加载，约 90 MB。
- 黑金风格（11-08）：钢琴漆黑海、金箔陆地（低频起伏加横向拉丝）；金面用金属高光加边缘反射，海面漆面高光，高光按高度减弱（近看不打爆）；深暖黑背景、球后淡暖光；底图首次切换才加载。
- 季风图层（11-08）：工具栏「季风」或 ⌘J，任何风格都能叠。逐月气候平均，每 2 秒走一个月，可拖动。画四样：
  - 地面风：6000 个粒子，计算着色器推进，每个留 40 帧轨迹；只在视野内的球冠里生成，缩放时屏幕密度不变；陆地和海上换色；
  - 降水：2 到 12 mm/天渐变着色，底图同时褪色 35%（地形 20%）；
  - 季风区轮廓：Wang & Ding 定义（夏季比冬季多 2.5 mm/天，且夏季占全年 55% 以上）；
  - 雨带中心虚线：25°S 到 30°N 内沿经度找降水最多的连续路径（Viterbi，跳纬度扣分），逐经线取最大值会来回跳。
  打开时若在看全球且没选中，会转到亚洲。底部时间轴有当月一句解说和图例。
- 海洋名 280 个（Natural Earth marine polys），宋体、拉开字距，所有风格都显示。
- 标签按所在位置（陆地或海上）换配色：复古、黑金在海上反色。
- 体验（11-08 评审后加）：面板打开时投影中心左移半个面板宽，选中处不被遮；首次打开底部有一句引导（`hasSelectedOnce`）；复古、黑金底图加载时顶部有提示；「地图」菜单 ⌘1–4 切风格、⌘F 搜索、⌘0 回全球、⌘D 3D、Esc 关面板；面板每节默认 4 行可展开；面板链接色随风格。
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
| build_climate.py | climate.bin：NCEP/NCAR 10 m 风 + GPCP 降水，1991–2020 月平均，重采样到 1° |

- 国界口径：Natural Earth 中国视角（admin_0_countries_chn）。台湾、香港、澳门是中国的省级区；藏南并入西藏（`DISSOLVE`）；其他争议区按多数像素所在国归属。
- 法、意、西、英的 admin-1 比省级细一级，按大区、自治区、构成国合并（`GROUP_BY`，Wikidata ID 已逐个核对）。
- ID 栅格 8192×4096：uint16 省 + uint8 国。CPU 点选和 GPU 高亮共用一块共享内存。
- 高程：AWS terrarium z5 瓦片（11-08 由 z4 升级），转成等经纬 8192×4096，约 5 km 一格。
- 卫星影像：EOX Sentinel-2 cloudless 2020，z6 瓦片。EOX 在南大洋和北冰洋有 544 张无数据瓦片（返回 1 位 PNG）；这些瓦片和 85° 以外的极区用 NE1 补，水面改成卫星深海色，接缝羽化 40 像素。**CC BY-NC-SA 4.0，只能非商业使用**，面板底部要署名。
- 内容：名人走 QLever 的 Wikidata 镜像（官方 WDQS 这类全库查询必超时），取语言版本数 ≥20 的人，按出生地或工作地坐标落进 ID 栅格；事件取有坐标的 occurrence。

## 性能（11-08，M1 Pro，Release，2560×1640）

- 自转时 GPU 每帧 4 到 5 ms，60 Hz 外接屏跑满。
- 按需绘制：静止时不出帧，空闲 CPU 0%。
- 内存 466 MB（11-08 加 3D 后），两张 16K 底图常驻。地形倾斜 60° 时 GPU 每帧约 6.8 ms。做过这些压缩：
  - 底图改 BC1 KTX：省掉 JPG 解码，少约 150 MB；
  - MSAA 颜色和深度改 memoryless：少约 130 MB；
  - ID 栅格、高程、网格直接写进共享显存，读文件用内存映射：少约 190 MB。临时大数组释放后分配器不还给系统，所以别用临时数组。
- 连续出帧（飞行、惯性、季风）用 GlobeMTKView 自己的 CADisplayLink，挂 common 模式；MTKView 一直 isPaused，静止时靠 setNeedsDisplay。11-08 修过：按下鼠标、滚轮会 stopMotion 把动画停掉，季风之后只靠悬停重画，看着一卡一卡。
- 季风月份每帧变但不让 SwiftUI 观察，时间轴按 15 Hz 跟进（每帧刷新时 CPU 45%，现在约 24%）。调试：`SHANHAI_FPS=1` 打印出帧率与上屏间隔，`SHANHAI_PLAY=1` 让季风自动播。
- 季风打开时持续出帧：全球视角 GPU 每帧约 6 ms（不开 4.5 ms），地形倾斜 50° 约 10 ms；内存约 400 MB。关掉后淡出完回到按需绘制。
- 标签按需排进 16 MB 图集，满了清空重排；碰撞检测用网格。

## 命令

- `xcodegen generate` 后构建；`scripts/install.sh` 装 Release 到 /Applications。
- 着色器在 `Shanhai/Resources/Shaders.msl`，运行时编译。本机 Xcode 没装 Metal 工具链，不依赖它。
- 截图调试：`open -n --env SHANHAI_PRINT_WINDOW=1 --env SHANHAI_CAMERA=纬,经,高度,倾斜,朝向 ...`，另有 `SHANHAI_MODE=terrain`、`SHANHAI_SELECT=纬,经`、`SHANHAI_HOVER=纬,经`、`SHANHAI_NOLABELS=1`、`SHANHAI_PRESS_3D=1`、`SHANHAI_MONSOON=7`（打开季风停在 7 月）。**直接执行二进制不出窗口**（沙盒应用），要用 `open`。
- 图标：`design/icon_shanhai.py` 程序绘制，`scripts/generate-icon.sh` 一步生成 icns。构图是海水江崖：团扇圆框里，青绿主峰从水纹中升起、冲出圆框，配朱日；山顶石青晕染到山脚石绿，不放文字。Felix 否掉过两轮：渲染地球四版太普通，罗盘、青绿、舆图三版是剪贴画。
- 离屏渲染地球：`SHANHAI_ICON=容器内路径.png`（沙盒只能写 `~/Library/Containers/io.github.chengffei.shanhai/Data/tmp`）。

## 待做

- 内容是维基原文，对零基础偏难。可以用 Claude 改写成大白话卡片。
- 地形近景受 16K 纹理限制（约 2.4 km/像素）。再清楚要做分块流式加载。
- 3D 与浮雕（11-08）：倾角高度 1.5 以下放开，0.6 以下到 60°；起伏放大倍数随高度 6 到 50 倍（`Camera.reliefExaggeration`）；地形用 2048×1024 网格，其他风格 512×256。
- 地形片元做浮雕：光源固定西北、仰角 35°；晕渲用细（1 格）粗（6 格）两尺度坡度；投影沿光源方向走 16 步，影子长度上限 min(2°, 高度×0.06)；环境光遮蔽比较周围两圈平均海拔；海拔亮度 0.93 到 1.08。明暗放大倍数是位移的 1.5 倍，最低 30 倍。区域视角 GPU 每帧约 8 ms。
- 地形网格约 20 km 一格，贴地近看山体位移仍偏粗（明暗按 5 km 高程算，已够清楚）。要更细得按视野分块做 LOD。
