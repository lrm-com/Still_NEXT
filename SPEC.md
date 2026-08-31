# Still — 桌面本地音乐播放器 技术规格文档

> 版本：0.3.0 | 最后更新：2026-08-30

---

## 1. 项目概述

**Still** 是一款跨平台（Windows / Linux / macOS）桌面本地音乐播放器，基于 Flutter Desktop 构建。追求 foobar2000 级别的音频功能深度与 BetterLyrics / SPlayer 级别的歌词视觉表现力，同时保持 Material 3 的精致 UI 风格。

### 1.1 核心定位

- 本地音乐管理与播放（非流媒体）
- 极致歌词体验（逐字动画、多模式、高度个性化）
- 高品质音频回放（gapless、ReplayGain、均衡器）
- 毛玻璃透明效果 + 深浅色模式
- 无系统原生标题栏 / 菜单栏，完全自绘窗口控制

### 1.2 技术栈

| 层级 | 技术 |
|---|---|
| 框架 | Flutter Desktop (stable channel) |
| 语言 | Dart 3.x |
| 渲染 | Impeller（默认）/ Skia（fallback） |
| 状态管理 | Riverpod 2.x |
| 本地存储 | Drift (SQLite) + SharedPreferences |
| 音频引擎 | just_audio（主引擎）+ miniaudio（Node Graph 后处理） |
| 音频服务 | audio_service（系统媒体控件集成） |
| 元数据 | on_audio_query / metadata_god |
| 毛玻璃 | flutter_acrylic（仅独立窗口：桌面歌词 / 任务栏歌词） |
| 窗口管理 | window_manager |
| 多窗口 | desktop_multi_window（桌面歌词 / 任务栏歌词） |
| 歌词渲染 | 自定义 CustomPainter + FragmentShader |
| 图片处理 | cached_network_image + palette_generator |
| 拼音搜索 | lpinyin（20,000+ CJK 字符完整映射） |
| 简繁转换 | chinese_convert（简繁互通搜索） |
| 国际化 | flutter_localizations + intl |
| 插件系统 | dart:ffi + 动态库加载（DSD 解码插件、歌词在线插件） |

---

## 2. 窗口与布局

### 2.1 窗口配置

```
最小尺寸：1024 × 640
默认尺寸：1280 × 800
无标题栏（frameless）
自定义窗口控制按钮（最小化 / 最大化 / 关闭）
可拖拽区域：标题栏 + 侧边栏顶部
可调整大小：四边 + 四角
全屏支持（F11 / 双击标题栏）
窗口状态持久化：记住位置、大小、最大化状态（跨重启）
```

### 2.2 毛玻璃效果

主窗口**不使用窗口级毛玻璃**，改用 Flutter 内置 `BackdropFilter` 实现局部毛玻璃效果。

**适用区域**：
- 底部播放控制栏
- 弹窗 / 对话框（设置、歌词源选择等）
- 侧边栏悬停状态

**实现方式**：
```dart
ClipRRect(
  borderRadius: BorderRadius.circular(12),
  child: BackdropFilter(
    filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
    child: Container(
      color: Colors.white.withOpacity(0.6),
      child: ChildWidget(),
    ),
  ),
)
```

**独立窗口**（桌面歌词 / 任务栏歌词）使用 `flutter_acrylic` 实现窗口级透明：
| 窗口 | 毛玻璃方式 |
|---|---|
| 主窗口 | `BackdropFilter` 局部毛玻璃 |
| 桌面歌词窗口 | `flutter_acrylic` 窗口级透明 |
| 任务栏歌词窗口 | `flutter_acrylic` 窗口级透明 |

**降级链**：`BackdropFilter 模糊 → 半透明纯色 → 纯色`

### 2.3 响应式断点

| 断点 | 布局调整 |
|---|---|
| < 620px | 侧边栏折叠，底部播放栏简化，歌词单列 |
| 620-820px | 侧边栏折叠，底部播放栏完整 |
| 820-980px | 侧边栏展开，底部播放栏完整 |
| 980-1280px | 侧边栏展开，歌词横屏模式可用 |
| > 1280px | 全功能布局 |

### 2.4 整体布局

```
┌─────────────────────────────────────────────────────┐
│  [自定义标题栏]  logo   导航←→   搜索栏   窗口控件  │
├────────┬────────────────────────────────────────────┤
│        │                                            │
│ 侧边栏 │           主内容区 (RouterView)            │
│ 200px  │                                            │
│ 可折叠 │                                            │
│        │                                            │
│        │                                            │
├────────┴────────────────────────────────────────────┤
│  [底部播放栏] 封面 歌曲信息 播放控制 进度条 音量 歌词 │
└─────────────────────────────────────────────────────┘
```

### 2.5 自定义标题栏

- 高度：40px
- 左侧：应用图标 + 应用名
- 中间：导航按钮（← →）+ 当前页面标题
- 右侧：搜索图标 + 设置图标 + 窗口控制按钮（最小化 / 最大化 / 关闭）
- 拖拽区域：标题栏整体（排除按钮区域）
- 关闭按钮悬停变红

### 2.6 侧边栏

- 宽度：200px（展开）/ 64px（折叠）
- 折叠按钮位于侧边栏底部
- 菜单项：歌曲、艺术家、专辑、文件夹、歌单（分隔线）设置
- 当前选中项高亮 + 左侧指示条（3px 圆角）
- 支持鼠标悬停展开预览（可选）

### 2.7 底部播放栏

- 高度：72px
- 左区：专辑封面（56×56，圆角 8px）+ 歌曲标题 + 艺术家名
- 中区：播放控制（随机、上一首、播放/暂停、下一首、循环）+ 进度条（可拖拽）
- 右区：音量按钮（点击展开滑块）+ 歌词按钮 + 翻译按钮 + 播放列表按钮
- 封面点击 → 进入歌词全屏界面
- 底部播放栏背景：毛玻璃效果

---

## 3. 页面结构

### 3.1 页面列表

| 页面 | 路由 | 可返回 |
|---|---|---|
| 歌曲列表 | `/songs` | ❌（最前页） |
| 艺术家列表 | `/artists` | → `/artists/:id` |
| 艺术家详情 | `/artists/:id` | ✅ |
| 专辑列表 | `/albums` | → `/albums/:id` |
| 专辑详情 | `/albums/:id` | ✅ |
| 文件夹列表 | `/folders` | → `/folders/:path` |
| 文件夹详情 | `/folders/:path` | ✅ |
| 歌单列表 | `/playlists` | → `/playlists/:id` |
| 歌单详情 | `/playlists/:id` | ✅ |
| 歌词全屏 | `/lyrics` | ✅（底部收起） |
| 库统计 | `/library/stats` | ✅ |
| 不可读曲目 | `/library/unreadable` | ✅ |
| 设置 | `/settings` | ✅ |

### 3.2 导航规则

- 所有页面均可通过 ← 按钮或手势返回上一页
- 歌曲列表为根页面，← 按钮置灰
- 页面切换动画：左右滑动（SlideTransition，200ms）
- 从底部播放栏点击封面进入歌词页：上滑动画（300ms，easeOutCubic）

---

## 4. 歌曲列表页

### 4.1 列表项信息

每行显示：

```
┌──────┬───────────────────────────────────────────────┐
│ 封面 │  歌曲标题                    艺术家 · 专辑     │
│ 48×48│  时长                        文件格式 · 码率   │
└──────┴───────────────────────────────────────────────┘
```

- 封面：48×48，圆角 6px，无封面时显示音符图标
- 标题：单行，溢出时 `MarqueeText` 悬停自动滚动
- 副标题：`艺术家 · 专辑`（灰色小字，可点击跳转）
- 第三行（可选）：`时长 · 格式 · 码率`（更淡灰色）
- 悬停效果：整行背景变半透明白色/黑色（跟随主题）
- 双击播放，右键弹出上下文菜单

### 4.2 上下文菜单

```
播放
添加到播放列表 → [歌单列表]
添加到队列
添加到文件夹
分隔线
查看艺术家      → 艺术家详情页
查看专辑        → 专辑详情页
分隔线
属性            → 弹窗显示完整文件信息
```

### 属性弹窗内容

```
┌─────────────────────────────────────────┐
│  歌曲属性                                │
│                                          │
│  标题：周杰伦                             │
│  艺术家：周杰伦                           │
│  专辑：范特西                             │
│  专辑艺术家：周杰伦                       │
│  年份：2001                               │
│  流派：Pop                                │
│  轨道号：03 / 10                          │
│  碟片号：1 / 1                            │
│                                          │
│  文件路径：D:\Music\周杰伦\范特西\03.mp3  │
│  文件大小：8.5 MB                         │
│  格式：MP3                                │
│  码率：320 kbps                           │
│  采样率：44100 Hz                         │
│  位深度：16 bit                           │
│  声道：立体声                             │
│  编码器：LAME 3.100                       │
│                                          │
│  歌词来源：内嵌 (ID3v2)                   │
│  封面来源：内嵌                           │
│                                          │
│  添加时间：2026-08-15                     │
│  最后播放：2026-08-30 14:32               │
│  播放次数：23                             │
│  收藏：♥                                  │
│                                          │
│           [关闭]                          │
└─────────────────────────────────────────┘
```

### 4.3 排序方式

| 排序 | 说明 |
|---|---|
| 手动 | 用户自定义顺序（拖拽） |
| 标题 A-Z | 按标题升序 |
| 标题 Z-A | 按标题降序 |
| 艺术家 | 按艺术家升序，**同艺术家按专辑年份从旧到新二级排序** |
| 专辑 | 按专辑名升序 |
| 年份 | 按年份升序 |
| 时长 | 按时长升序 |
| 添加时间 | 按添加时间降序 |
| 文件名 | 按文件名排序 |

### 4.4 搜索

- 基于 `lpinyin` 的全量拼音搜索，覆盖 20,000+ CJK 字符
- 支持输入方式：
  - 全拼：`"zhoujielun"` 匹配 `"周杰伦"`
  - 拼音首字母：`"zjl"` 匹配 `"周杰伦"`
  - 混合：`"jay zjl"` 同时匹配英文和拼音
  - 原文：直接匹配歌曲标题 / 艺术家 / 专辑名
  - 简繁互通：搜索 `"周傑倫"` 也能匹配 `"周杰伦"`（基于 `chinese_convert_service`）
- 搜索范围：标题、艺术家、专辑、文件名
- 实时搜索（输入即过滤，debounce 200ms）
- 多音字智能判断（基于词语上下文，如 `"重庆"` → `"chongqing"`）

### 4.5 字母索引

- 歌曲列表右侧显示 A-Z 字母索引条
- 滚动时显示当前首字母的浮层气泡（200ms 后淡出）
- 点击字母跳转到对应位置
- 基于拼音首字母分组（中文歌曲自动转换）

### 4.6 滚动条

- 使用 Flutter 原生 `Scrollbar` 组件
- `thumbVisibility: true`，始终显示滚动条
- 悬停时显示字母气泡指示器
- 平滑滚动，支持鼠标滚轮

### 4.7 顶部操作栏

```
[排序方式▼] [视图切换(列表/网格)] [选择模式] [随机播放] [全部播放] [搜索]
```

---

## 5. 艺术家页面

### 5.1 艺术家列表

- 视图：网格（封面 120×120）或列表
- 列表项：封面 + 艺术家名 + 歌曲数
- 点击进入艺术家详情页

### 5.2 艺术家详情页

```
┌─────────────────────────────────────────────────┐
│  [← 返回]                                        │
│                                                  │
│  ┌──────────┐  艺术家名称                         │
│  │  封面     │  X 张专辑 · Y 首歌                  │
│  │  160×160 │  [随机播放] [全部播放]               │
│  └──────────┘                                    │
│                                                  │
│  ── 热门歌曲 ──────────────────────────────       │
│  1. 歌曲标题1          3:42                       │
│  2. 歌曲标题2          4:15                       │
│  3. 歌曲标题3          3:58                       │
│                                                  │
│  ── 专辑 ─────────────────────────────────       │
│  ┌────┐ ┌────┐ ┌────┐ ┌────┐                    │
│  │封面1│ │封面2│ │封面3│ │封面4│                    │
│  │年份 │ │年份 │ │年份 │ │年份 │                    │
│  └────┘ └────┘ └────┘ └────┘                    │
│                                                  │
│  ── 相关艺术家 ──────────────────────────         │
│  [艺术家A] [艺术家B] [艺术家C]                    │
└─────────────────────────────────────────────────┘
```

- 封面：从该艺术家所有专辑封面中取第一张
- 热门歌曲：默认显示前 10 首，可展开
- 专辑：横向滚动，按年份从旧到新
- 相关艺术家：同专辑合作的其他艺术家
- 歌曲列表中艺术家名、专辑名可点击跳转

---

## 6. 专辑页面

### 6.1 专辑列表

- 视图：网格（封面 160×160 + 专辑名 + 艺术家 + 年份）
- 支持按艺术家、年份分组

### 6.2 专辑详情页

```
┌─────────────────────────────────────────────────┐
│  [← 返回]                                        │
│                                                  │
│  ┌──────────┐  专辑名称                           │
│  │  封面     │  艺术家名 · 年份                    │
│  │  200×200 │  X 首歌 · 总时长                    │
│  │  圆角 12 │  [随机播放] [全部播放]               │
│  └──────────┘                                    │
│                                                  │
│  ── 曲目 ────────────────────────────────         │
│  01  歌曲标题1              艺术家A    3:42       │
│  02  歌曲标题2              艺术家A    4:15       │
│  03  歌曲标题3 feat.B      艺术家A,B  3:58       │
│  04  歌曲标题4              艺术家A    5:01       │
│                                                  │
│  ── 专辑信息 ────────────────────────────         │
│  流派：Pop    发行日期：2024-03-15                │
│  唱片公司：XXX                                    │
│  涉及艺术家：艺术家A, 艺术家B                      │
└─────────────────────────────────────────────────┘
```

- 曲目列表：音轨号（2位补零）+ 标题 + 艺术家（如不同）+ 时长
- 双击播放，右键菜单同歌曲列表
- 标题、艺术家名可点击跳转
- 无封面时显示专辑图标占位

---

## 7. 文件夹页面

### 7.1 文件夹列表

```
┌─────────────────────────────────────────────────┐
│  [添加文件夹]                                     │
│                                                  │
│  📁 D:\Music\Pop                                 │
│     156 首歌 · 最后扫描：2026-08-30               │
│                                                  │
│  📁 D:\Music\Classical                           │
│     89 首歌 · 最后扫描：2026-08-30                │
│                                                  │
│  📁 E:\Music\Jazz                                │
│     234 首歌 · 最后扫描：2026-08-28               │
└─────────────────────────────────────────────────┘
```

### 7.2 文件夹详情

- 进入后显示该文件夹内所有歌曲（递归扫描）
- 支持子文件夹导航
- 顶部显示路径面包屑
- 元数据缓存：扫描结果缓存到本地，避免重复解析（文件修改时间校验）

---

## 8. 库统计页面

```
┌─────────────────────────────────────────────────┐
│  库统计                                          │
│                                                  │
│  ── 概览 ──────────────────────────────          │
│  总歌曲数：1,234                                 │
│  总时长：82 小时 15 分钟                          │
│  总文件大小：4.2 GB                               │
│  总艺术家数：89                                   │
│  总专辑数：156                                    │
│                                                  │
│  ── 格式分布 ──────────────────────────          │
│  FLAC  ████████████████  45% (556)               │
│  MP3   ████████████      30% (370)               │
│  AAC   ██████            15% (185)               │
│  OGG   ████              10% (123)               │
│                                                  │
│  ── 码率分布 ──────────────────────────          │
│  320kbps  ██████████████  40%                    │
│  无损     ████████████    35%                    │
│  128kbps  ██████          15%                    │
│  其他     ████            10%                    │
│                                                  │
│  ── 最近播放 Top 10 ───────────────────          │
│  1. 歌曲A    播放 45 次                           │
│  2. 歌曲B    播放 38 次                           │
│  ...                                             │
└─────────────────────────────────────────────────┘
```

---

## 9. 不可读曲目页面

```
┌─────────────────────────────────────────────────┐
│  不可读曲目 (12 首)                               │
│  [重试扫描] [批量移除]                             │
│                                                  │
│  ⚠ 歌曲标题1                                     │
│    路径：D:\Music\missing.mp3                     │
│    原因：文件不存在                                │
│    [重链] [移除]                                  │
│                                                  │
│  ⚠ 歌曲标题2                                     │
│    路径：D:\Music\corrupt.flac                    │
│    原因：文件损坏，无法解码                        │
│    [重链] [移除]                                  │
│                                                  │
│  ⚠ 歌曲标题3                                     │
│    路径：E:\Music\old.mp3                         │
│    原因：权限不足                                  │
│    [重链] [移除]                                  │
└─────────────────────────────────────────────────┘
```

---

## 10. 歌单管理

### 10.1 歌单列表

```
┌─────────────────────────────────────────────────┐
│  [新建歌单]                                       │
│                                                  │
│  ♥ 我喜欢的音乐          45 首                    │
│  ─────────────────────────                       │
│  🎵 最近播放              30 首                    │
│  🎵 自定义歌单A           12 首                    │
│  🎵 自定义歌单B           8 首                     │
└─────────────────────────────────────────────────┘
```

### 10.2 歌单操作

- 新建歌单：输入名称 + 可选封面
- 重命名 / 删除歌单
- 拖拽排序歌单
- 拖拽歌曲到歌单
- 歌单内歌曲可拖拽排序
- 批量添加/移除歌曲

---

## 11. 歌词系统

### 11.1 歌词来源优先级

1. LRC 文件（同目录下同名 .lrc）
2. 歌曲内嵌歌词（ID3v2 USLT / Vorbis Comment LYRICS）
3. 网络歌词 API（可选扩展）

### 11.2 歌词解析

- 支持标准 LRC 格式 `[mm:ss.xx]`
- 支持扩展 LRC `[mm:ss.xxx]`
- 支持逐字 LRC（YRC 格式 `[mm:ss.xx]<mm:ss.xx>字<mm:ss.xx>符`）
- 支持翻译歌词（`[tr:语言标签]` 或独立 LRC 文件 `xxx.translated.lrc`）

### 11.3 歌词界面入口

- 点击底部播放栏左下角专辑封面 → 上滑进入歌词全屏界面
- 歌词界面左下角显示缩小的专辑封面（点击可返回）

### 11.4 歌词全屏界面布局

#### 模式一：纯歌词模式

```
┌─────────────────────────────────────────────────┐
│                                                  │
│                                                  │
│            歌词行1（非当前，模糊 + 淡出）           │
│            歌词行2（非当前，模糊 + 淡出）           │
│         ➤ 歌词行3（当前行，高亮 + 缩放 + 发光）    │
│            歌词行4（非当前，模糊 + 淡出）           │
│            歌词行5（非当前，模糊 + 淡出）           │
│                                                  │
│                                                  │
│  [封面]                              [翻译] [关闭] │
└─────────────────────────────────────────────────┘
```

- 背景：封面模糊 + 半透明遮罩
- 歌词居中，左右两侧渐变遮罩

#### 模式二：纯专辑封面模式

```
┌─────────────────────────────────────────────────┐
│                                                  │
│                                                  │
│            ┌──────────────────┐                  │
│            │                  │                  │
│            │    专辑封面       │                  │
│            │   （大尺寸居中）   │                  │
│            │                  │                  │
│            └──────────────────┘                  │
│                                                  │
│         歌曲标题 · 艺术家名                       │
│  [封面]                              [翻译] [关闭] │
└─────────────────────────────────────────────────┘
```

- 封面带阴影 + 圆角
- 底部显示歌曲标题和艺术家

#### 模式三：横屏封面歌词混合模式

```
┌─────────────────────────────────────────────────┐
│                                                  │
│  ┌──────────────┐        歌词行1                 │
│  │              │        歌词行2                  │
│  │   专辑封面    │     ➤ 歌词行3（当前）           │
│  │              │        歌词行4                  │
│  │  300×300     │        歌词行5                  │
│  └──────────────┘                               │
│                                                  │
│  歌曲标题 · 艺术家名       [翻译] [关闭]          │
└─────────────────────────────────────────────────┘
```

- 封面占左侧约 40%，歌词占右侧 60%
- 封面带圆角（16px）+ 投影

#### 模式四：竖屏封面歌词混合模式

```
┌─────────────────────────────────────────────────┐
│                                                  │
│           ┌──────────────────┐                   │
│           │                  │                   │
│           │    专辑封面       │                   │
│           │   240×240        │                   │
│           └──────────────────┘                   │
│                                                  │
│           歌词行1                                │
│           歌词行2                                │
│        ➤ 歌词行3（当前）                          │
│           歌词行4                                │
│           歌词行5                                │
│                                                  │
│  [封面]                     歌曲标题   [翻译][关闭]│
└─────────────────────────────────────────────────┘
```

- 封面上方居中，歌词在下方
- 封面 + 歌词上下排列

### 11.5 歌词动画

#### 模式切换过渡动画

四种模式之间切换时，专辑封面执行位置过渡动画：

- 纯歌词模式 → 横屏模式：封面从底部缩略图位置移动到左侧大封面位置
- 纯歌词模式 → 竖屏模式：封面从底部缩略图位置移动到上方居中位置
- 纯歌词模式 → 纯封面模式：封面从底部缩略图位置放大到屏幕中央
- 所有模式收起时：封面从当前位置缩小回底部播放栏位置

动画参数：
- 时长：400ms
- 曲线：`Curves.easeInOutCubic`
- 使用 `Hero` 动画 + `AnimationController` 驱动

#### 歌词逐字动画

```
当前行：
  - 整行：放大 1.05x + 向上偏移 2px + 不透明度 1.0
  - 已唱部分：主色调填充
  - 未唱部分：次色调填充 + 逐字渐变揭示

非当前行：
  - 距离当前行越远，模糊越大（max 8px）
  - 不透明度随距离递减（min 0.3）
  - 整行静止，无动画

滚动：
  - 自动滚动到当前行居中位置
  - 滚动动画：300ms easeOutCubic
  - 用户手动滚动时暂停自动滚动 3 秒
```

#### 歌词翻译动画

- 底栏翻译按钮：有翻译时正常色，无翻译时灰色（不可点击）
- 开启翻译：翻译文本从主歌词行下方展开（`SizeTransition`，200ms）
- 关闭翻译：翻译文本收缩回主歌词行下方（`SizeTransition`，200ms）
- 翻译文本字号为主歌词的 75%
- 翻译文本颜色比主歌词淡一级

### 11.6 歌词点击跳转

- 点击任意歌词行 → 播放进度跳转到该行对应时间
- 跳转后自动滚动到点击的歌词行
- 跳转时目标行有轻微缩放反馈动画（1.0 → 1.05 → 1.0，200ms）

### 11.7 歌词偏移

- 支持全局歌词偏移（±10 秒，步进 0.1 秒）
- 偏移值持久化保存
- 界面显示偏移量，可手动调整

---

## 12. 底部播放栏详情

### 12.0 视觉效果

底部播放栏使用 `BackdropFilter` 实现局部毛玻璃效果：

```dart
ClipRRect(
  borderRadius: BorderRadius.vertical(top: Radius.circular(12)),
  child: BackdropFilter(
    filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
    child: Container(
      color: surfaceColor.withOpacity(0.7),  // 半透明底色
      child: PlaybackBarContent(),
    ),
  ),
)
```

- 背景：半透明 + 模糊（`sigma: 20`）
- 圆角：顶部 12px
- 与主内容区之间有分割线（1px，半透明）
- 深色模式下底色自动调整

### 12.1 进度条

- 高度：4px（默认）→ 悬停时 6px
- 已播放部分：主题色
- 未播放部分：半透明白色/黑色
- 悬停时显示时间气泡
- 可拖拽 seek
- 缓冲进度：更浅的进度条（如支持流媒体）

### 12.2 音量控制

- 点击音量图标展开滑块
- 滑块垂直方向，从底部向上
- 0% / 33% / 66% / 100% 四档图标
- 点击图标切换静音
- 音量持久化

### 12.3 播放模式

- 顺序播放
- 随机播放
- 列表循环
- 单曲循环
- 图标跟随模式切换动画

---

## 13. 音频引擎架构

### 13.1 双引擎架构

```
┌─────────────────────────────────────────────────────────┐
│  just_audio（主引擎）                                     │
│  ├── 解码：MP3 / FLAC / OGG / AAC / WAV / AIFF / Opus  │
│  ├── 播放控制：play / pause / seek / speed / volume      │
│  ├── 播放模式：顺序 / 随机 / 列表循环 / 单曲循环          │
│  ├── Gapless 无缝播放                                    │
│  └── 本地文件 file:// 直读（零网络依赖）                   │
│                                                          │
│  音频流输出 → PCM Buffer                                  │
│       │                                                  │
│       ▼                                                  │
│  miniaudio Node Graph（后处理引擎）                       │
│  ├── 均衡器节点（10 段 Biquad Filter）                    │
│  ├── 频谱分析节点（FFT 1024 点）                          │
│  ├── 低音增强 / 高音增强节点                              │
│  ├── 音量增益节点                                        │
│  └── 淡入淡出节点                                        │
│       │                                                  │
│       ▼                                                  │
│  系统音频输出（WASAPI / CoreAudio / ALSA）                │
└─────────────────────────────────────────────────────────┘
```

### 13.2 为什么用双引擎

| 职责 | just_audio | miniaudio Node Graph |
|---|---|---|
| 音频解码 | ✅ 主引擎 | ❌ 不解码 |
| 播放控制 | ✅ play/pause/seek | ❌ |
| Gapless | ✅ 原生支持 | ❌ |
| 均衡器 | ❌ 无内置 | ✅ Biquad Filter 节点 |
| 频谱分析 | ❌ 无内置 | ✅ FFT 节点 |
| 音频后处理 | ❌ | ✅ Node Graph 灵活组合 |
| 跨平台 | ✅ | ✅ |

### 13.3 支持格式

| 格式 | 编码 | 解码引擎 |
|---|---|---|
| MP3 | MPEG-1 Audio Layer III | just_audio |
| FLAC | Free Lossless Audio Codec | just_audio |
| OGG | Ogg Vorbis | just_audio |
| AAC | Advanced Audio Coding | just_audio |
| M4A | AAC / ALAC (Apple Lossless) | just_audio |
| WAV | Waveform Audio | just_audio |
| AIFF | Audio Interchange File Format | just_audio |
| Opus | Opus Interactive Audio Codec | just_audio |
| WMA | Windows Media Audio | just_audio |
| DSD (DSF/DFF) | Direct Stream Digital | **插件**（miniaudio Node Graph） |

### 13.4 播放控制

- 播放 / 暂停
- 上一首 / 下一首
- 进度 seek（精确到毫秒）
- 播放速度（0.5x - 2.0x）
- 无缝播放（gapless）
- 淡入淡出（可选，可配置时长）
- 本地文件直接播放（`just_audio` 通过 `file://` 路径读取，**无需 HTTP 服务器**，零网络依赖）

### 13.5 均衡器（miniaudio Node Graph）

- 10 段图形均衡器（31Hz, 62Hz, 125Hz, 250Hz, 500Hz, 1kHz, 2kHz, 4kHz, 8kHz, 16kHz）
- 实现：miniaudio `ma_biquad` 节点串联
- 预设：平坦、摇滚、流行、爵士、古典、舞曲、人声、自定义
- 增益范围：-12dB ~ +12dB
- 低音增强 / 高音增强（独立开关，miniaudio 滤波器节点）
- 实时调节：Node Graph 支持热切换参数，无需重启播放

```
miniaudio Node Graph:

  PCM Input
      │
      ▼
  ┌──────────────┐
  │ Biquad Node  │ ← 31Hz 均衡
  └──────┬───────┘
         │
  ┌──────▼───────┐
  │ Biquad Node  │ ← 62Hz 均衡
  └──────┬───────┘
         │
      ...（共 10 个）
         │
  ┌──────▼───────┐
  │ Biquad Node  │ ← 低音增强
  └──────┬───────┘
         │
  ┌──────▼───────┐
  │ Biquad Node  │ ← 高音增强
  └──────┬───────┘
         │
  ┌──────▼───────┐
  │ Gain Node    │ ← 音量增益
  └──────┬───────┘
         │
  ┌──────▼───────┐
  │ Fade Node    │ ← 淡入淡出
  └──────┬───────┘
         │
         ▼
  系统音频输出
```

### 13.6 频谱分析（miniaudio Node Graph）

- FFT 窗口大小：1024 点（可配置 512 / 1024 / 2048）
- 频谱数据通过 FFI 回调到 Dart 层
- Dart 层负责渲染（CustomPainter），不阻塞音频线程

```
miniaudio Node Graph:

  PCM Input
      │
      ├──→ 均衡器 Node Graph ──→ 系统音频输出
      │
      └──→ FFT Node ──→ 频谱数据回调 → Dart CustomPainter
```

### 13.7 ReplayGain

- 支持 Track Gain 和 Album Gain
- 扫描模式：EBU R128（默认）/ 经典 ReplayGain
- 预增益设置
- 防削波
- 标签写入支持

### 13.8 音频信息

实时显示：
- 采样率（如 44100 Hz）
- 位深度（如 16 bit / 24 bit）
- 声道（立体声 / 单声道 / 多声道）
- 码率（如 320 kbps / 1411 kbps）
- 编码器信息

### 13.9 标签编辑

支持编辑：
- 标题、艺术家、专辑、专辑艺术家
- 年份、流派、轨道号、碟片号
- 评论
- 封面图片（查看 / 替换 / 删除）
- 批量编辑

### 13.10 转码

- 集成 FFmpeg 命令行工具
- 输出格式：MP3 (LAME)、FLAC、OGG Vorbis、Opus、AAC
- 可配置码率 / 质量
- 输出目录设置
- 转码进度显示

---

## 14. 频谱可视化

### 14.1 频谱数据来源

- 数据由 miniaudio FFT Node 提供，通过 FFI 回调到 Dart
- 回调频率：每秒约 60 次（与帧率同步）
- 数据格式：`Float32List`（FFT 幅度值，已对数缩放）

### 14.2 频谱显示

- 位置：底部播放栏（迷你频谱）/ 歌词全屏界面（背景频谱）
- 样式：
  - 柱状（Bar）：垂直柱，顶部圆角
  - 曲线（Curve）：平滑 B-Spline 曲线
- 颜色：跟随主题色 / 封面主色 / 自定义
- 条数：可配置（16-128）

### 14.3 背景频谱（歌词界面）

- 位置：歌词文字下方，全屏高度
- 透明度：可配置（10%-50%）
- 混合模式：screen / plus-lighter

---

## 15. 背景特效（歌词界面）

### 15.1 背景模式

| 模式 | 说明 |
|---|---|
| 封面模糊 | 封面放大 1.5x + 高斯模糊 80px + 对比度增强 + 半透明遮罩 |
| 提取色 | 从封面提取主色调，渐变背景 |
| 流体渐变 | GLSL 着色器，响应音频能量的流动渐变 |
| 纯色 | 用户自定义纯色 |
| 无 | 透明/纯黑 |

### 15.2 粒子特效（可叠加）

| 特效 | 说明 |
|---|---|
| 雪花 | GPU 粒子，密度/速度可调 |
| 雾 | 程序化雾气，随时间变化 |
| 雨滴 | GPU 着色器，速度/密度/光线角度可调 |

- 所有特效支持呼吸效果（音频低频能量驱动缩放）
- 所有特效支持视差效果（跟随鼠标 / 陀螺仪）

---

## 16. 设置页面

### 16.1 常规

- 语言（简体中文 / English）
- 开机自启动
- 关闭窗口时最小化到托盘
- 通知区域图标
- 全局快捷键（可自定义）

### 16.2 外观

- 深色 / 浅色 / 跟随系统
- 主题色选择（Primary Color）
- 强调色（Accent Color）
- **Monet 动态主题**：
  - 自动模式：从当前播放歌曲封面提取主色调，生成完整 HSL 色系
  - 手动模式：用户自定义种子色
  - 色系生成算法：中性表面色带微弱色调偏移 + 强调色用于控件/高亮
  - 对比度自动计算：确保文字在强调色背景上可读
- 毛玻璃强度（可调节 BackdropFilter 的 opacity / blur 半径）
- 侧边栏样式
- 字体选择（正文 / 歌词 / CJK）
- 页面切换动画类型（滑动 / 淡入 / 缩放 / 流动）

### 16.3 弹窗视觉效果

所有弹窗 / 对话框使用 `BackdropFilter` 实现局部毛玻璃效果：

```dart
showDialog(
  builder: (context) => ClipRRect(
    borderRadius: BorderRadius.circular(16),
    child: BackdropFilter(
      filter: ImageFilter.blur(sigmaX: 30, sigmaY: 30),
      child: Container(
        color: surfaceColor.withOpacity(0.5),
        child: DialogContent(),
      ),
    ),
  ),
)
```

适用弹窗：
- 设置弹窗
- 歌词源选择器
- 歌曲属性弹窗
- 标签编辑弹窗
- 确认对话框
- 关于弹窗

弹窗背景：半透明底色 + 模糊（`sigma: 30`）
弹窗圆角：16px
弹窗外层遮罩：`Colors.black.withOpacity(0.3)`（不模糊，仅半透明）

### 16.4 播放

- 无缝播放开关
- 淡入淡出时长
- 播出质量（采样率 / 位深）
- ReplayGain 设置
- 均衡器
- 播放速率（0.1x - 3x）

### 16.5 歌词

- 默认显示模式（纯歌词 / 纯封面 / 横屏混合 / 竖屏混合）
- 默认背景模式（封面模糊 / 提取色 / 流体 / 纯色 / 无）
- **歌词字体设置**：
  - 字体大小（主歌词 / 翻译歌词，独立调节）
  - 字重（Thin → Extra Black，11 级）
  - 描边宽度（0-10px）
  - CJK 字体与西文字体分别选择
- **歌词位置**：
  - 对齐方式（左 / 居中 / 右）
  - 播放行偏移（1%-99%，控制当前行在屏幕的位置）
  - 左侧偏移（微调水平位置）
- **歌词动画**：
  - 逐字渐变扫描（开/关/自动）
  - 模糊效果（非当前行模糊，max 可调）
  - 淡出效果（非当前行不透明度递减）
  - 缩放效果（当前行放大 100%-200%）
  - 浮动动画（字符上下浮动，可调幅度和时长）
  - 扇形歌词（行旋转形成弧形，角度 -90° ~ +90°）
  - 3D 透视（X/Y/Z 旋转 + 深度，自动/手动）
  - 呼吸效果（音频低频能量驱动整体缩放）
  - 已播放行隐藏（可选）
  - 远距视图（远离当前行的额外处理）
- **滚动设置**：
  - 滚动动画时长（顶部/普通/底部分别设置）
  - 12 种缓动函数可选
- 歌词偏移（±10 秒，步进 0.1 秒）
- 歌词复制选项
- 网络歌词 API 配置

### 16.6 桌面歌词

- 窗口锁定/解锁
- 字体设置（字体 / 字号 / 字重）
- 第二行字号（独立调节）
- 已唱颜色（自定义）
- 未唱颜色（自定义）
- 描边颜色（自定义）
- 双行显示开关
- 翻译行开关
- 逐字高亮开关
- 窗口透明度
- 位置和尺寸记忆

### 16.7 库

- 音乐文件夹管理
- 文件格式过滤
- 自动扫描间隔
- 手动扫描按钮

### 16.8 数据

- 导出播放列表（M3U / PLS / XSPF）
- 导入播放列表（M3U / PLS / XSPF / FPL）
- 清除缓存（封面缓存 / 元数据缓存）
- 数据库备份 / 恢复

---

## 17. 数据模型

### 17.1 核心表

```sql
-- 歌曲
CREATE TABLE songs (
  id INTEGER PRIMARY KEY,
  title TEXT,
  artist TEXT,
  album TEXT,
  album_artist TEXT,
  year INTEGER,
  genre TEXT,
  track_number INTEGER,
  disc_number INTEGER,
  duration_ms INTEGER,
  file_path TEXT UNIQUE,
  file_size INTEGER,
  file_format TEXT,
  bitrate INTEGER,
  sample_rate INTEGER,
  bit_depth INTEGER,
  cover_path TEXT,
  lrc_path TEXT,
  has_lyrics INTEGER DEFAULT 0,
  has_translated_lyrics INTEGER DEFAULT 0,
  replaygain_track_gain REAL,
  replaygain_track_peak REAL,
  replaygain_album_gain REAL,
  replaygain_album_peak REAL,
  added_at DATETIME DEFAULT CURRENT_TIMESTAMP,
  last_played_at DATETIME,
  play_count INTEGER DEFAULT 0,
  favorite INTEGER DEFAULT 0
);

-- 歌单
CREATE TABLE playlists (
  id INTEGER PRIMARY KEY,
  name TEXT NOT NULL,
  cover_path TEXT,
  created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
  updated_at DATETIME,
  sort_order INTEGER DEFAULT 0
);

-- 歌单-歌曲关联
CREATE TABLE playlist_songs (
  id INTEGER PRIMARY KEY,
  playlist_id INTEGER REFERENCES playlists(id) ON DELETE CASCADE,
  song_id INTEGER REFERENCES songs(id) ON DELETE CASCADE,
  sort_order INTEGER DEFAULT 0,
  added_at DATETIME DEFAULT CURRENT_TIMESTAMP
);

-- 音乐文件夹
CREATE TABLE folders (
  id INTEGER PRIMARY KEY,
  path TEXT UNIQUE NOT NULL,
  name TEXT,
  song_count INTEGER DEFAULT 0,
  last_scanned_at DATETIME
);

-- 歌词
CREATE TABLE lyrics (
  id INTEGER PRIMARY KEY,
  song_id INTEGER REFERENCES songs(id) ON DELETE CASCADE,
  content TEXT,           -- LRC 原文
  translated TEXT,        -- 翻译内容
  source TEXT,            -- 来源: lrc_file / embedded / network
  offset_ms INTEGER DEFAULT 0,
  UNIQUE(song_id)
);

-- 设置（键值对）
CREATE TABLE settings (
  key TEXT PRIMARY KEY,
  value TEXT
);
```

---

## 18. 项目结构

```
<project-root>\
├── SPEC.md                          # 本文档
├── pubspec.yaml
├── lib/
│   ├── main.dart                    # 入口
│   ├── app.dart                     # MaterialApp + 路由
│   ├── core/
│   │   ├── constants/               # 常量定义
│   │   ├── theme/                   # 主题（颜色、字体、形状）
│   │   │   ├── app_theme.dart
│   │   │   ├── color_schemes.dart
│   │   │   └── text_styles.dart
│   │   ├── utils/                   # 工具类
│   │   │   ├── lrc_parser.dart      # LRC 解析器
│   │   │   ├── pinyin_utils.dart    # 拼音搜索工具（基于 lpinyin）
│   │   │   ├── format_utils.dart    # 格式化工具
│   │   │   └── file_utils.dart      # 文件操作工具
│   │   └── extensions/              # Dart 扩展
│   ├── models/                      # 数据模型
│   │   ├── song.dart
│   │   ├── playlist.dart
│   │   ├── album.dart
│   │   ├── artist.dart
│   │   ├── folder.dart
│   │   ├── lyrics.dart
│   │   └── audio_info.dart
│   ├── services/                    # 服务层
│   │   ├── audio_service.dart       # 音频播放服务
│   │   ├── database_service.dart    # SQLite 数据库
│   │   ├── scanner_service.dart     # 音乐扫描服务
│   │   ├── metadata_service.dart    # 元数据提取
│   │   ├── metadata_cache_service.dart # 元数据缓存
│   │   ├── cover_service.dart       # 封面发现与缓存
│   │   ├── cover_color_service.dart # 封面主色提取（Monet 主题）
│   │   ├── lyrics_service.dart      # 歌词加载/搜索
│   │   ├── tray_service.dart        # 系统托盘
│   │   ├── media_session_service.dart # OS 媒体会话
│   │   ├── window_state_service.dart # 窗口状态持久化
│   │   ├── chinese_convert_service.dart # 简繁转换
│   │   └── settings_service.dart    # 设置持久化
│   ├── providers/                   # Riverpod 状态管理
│   │   ├── audio_provider.dart
│   │   ├── library_provider.dart
│   │   ├── playlist_provider.dart
│   │   ├── lyrics_provider.dart
│   │   ├── settings_provider.dart
│   │   └── theme_provider.dart
│   ├── views/                       # 页面
│   │   ├── layout/
│   │   │   ├── app_layout.dart      # 整体布局
│   │   │   ├── sidebar.dart         # 侧边栏
│   │   │   ├── title_bar.dart       # 自定义标题栏
│   │   │   └── bottom_player.dart   # 底部播放栏
│   │   ├── songs/
│   │   │   ├── songs_page.dart
│   │   │   └── song_tile.dart
│   │   ├── artists/
│   │   │   ├── artists_page.dart
│   │   │   └── artist_detail_page.dart
│   │   ├── albums/
│   │   │   ├── albums_page.dart
│   │   │   └── album_detail_page.dart
│   │   ├── folders/
│   │   │   ├── folders_page.dart
│   │   │   └── folder_detail_page.dart
│   │   ├── playlists/
│   │   │   ├── playlists_page.dart
│   │   │   └── playlist_detail_page.dart
│   │   ├── lyrics/
│   │   │   ├── lyrics_fullscreen_page.dart
│   │   │   ├── lyrics_overlay.dart
│   │   │   ├── desktop_lyrics_window.dart
│   │   │   └── translation_toggle.dart
│   │   ├── queue/                      # 播放队列
│   │   │   └── queue_panel.dart
│   │   └── settings/
│   │       ├── settings_page.dart
│   │       ├── appearance_settings.dart
│   │       ├── audio_settings.dart
│   │       ├── lyrics_settings.dart
│   │       └── desktop_lyrics_settings.dart
│   │   ├── library/                     # 库管理
│   │   │   ├── library_stats_page.dart  # 库统计
│   │   │   └── unreadable_page.dart     # 不可读曲目列表
│   ├── widgets/                     # 可复用组件
│   │   ├── album_cover.dart         # 封面组件（带占位）
│   │   ├── progress_bar.dart        # 进度条
│   │   ├── volume_slider.dart       # 音量滑块
│   │   ├── context_menu.dart        # 右键菜单（毛玻璃 + 圆角）
│   │   ├── sort_menu.dart           # 排序菜单
│   │   ├── search_bar.dart          # 搜索栏
│   │   ├── glass_container.dart     # 毛玻璃容器
│   │   ├── animated_cover.dart      # 封面动画组件
│   │   ├── alphabet_index.dart      # 字母索引条
│   │   ├── marquee_text.dart        # 长文本悬停滚动
│   │   ├── virtual_track_list.dart  # 虚拟滚动歌曲列表
│   │   ├── track_info_dialog.dart   # 歌曲属性弹窗
│   │   └── number_control.dart      # 数字输入控件
│   └── renderers/                   # 自定义渲染器
│       ├── lyrics_painter.dart      # 歌词绘制（CustomPainter）
│       ├── spectrum_painter.dart    # 频谱绘制
│       ├── fluid_background.dart    # 流体背景（FragmentShader）
│       ├── snow_painter.dart        # 雪花粒子
│       ├── fog_painter.dart         # 雾气效果
│       └── raindrop_painter.dart    # 雨滴效果
├── assets/
│   ├── shaders/                     # GLSL 着色器
│   │   ├── fluid_background.frag
│   │   ├── snow.frag
│   │   ├── fog.frag
│   │   └── raindrop.frag
│   ├── images/                      # 图片资源
│   │   ├── placeholder_cover.png
│   │   └── icons/
│   └── fonts/                       # 自定义字体
│       └── NotoSansSC/
├── linux/
├── macos/
├── windows/
└── test/
```

---

## 19. 开发优先级

### P0 — 核心功能（MVP）

1. 项目脚手架搭建（Flutter Desktop + Riverpod + Drift）
2. 窗口管理（无标题栏 + 毛玻璃 + 深浅色）
3. 音频引擎（just_audio 集成）
4. 音乐扫描与元数据提取
5. 歌曲列表页（排序、搜索、播放）
6. 底部播放栏（进度条、控制、音量）
7. 基础歌词显示（LRC 解析 + 同步滚动）

### P1 — 完整功能

8. 艺术家列表 + 详情页
9. 专辑列表 + 详情页
10. 文件夹管理
11. 歌单管理
12. 歌词全屏界面（4 种模式）
13. 歌词翻译 + 切换动画
14. 深浅色切换动画

### P2 — 高级功能

15. 逐字卡拉OK 歌词动画
16. 歌词背景特效（模糊、流体、粒子）
17. 频谱可视化（miniaudio FFT Node）
18. 均衡器（miniaudio Biquad Node）
19. ReplayGain
20. 标签编辑器
21. 转码功能
22. 桌面歌词窗口（desktop_multi_window）
23. 任务栏歌词窗口（Windows 覆盖窗口）
24. 系统托盘集成
25. 媒体会话（OS 媒体控件）

### P3 — 增强功能

26. 全局快捷键
27. Last.fm 集成
28. 导入/导出播放列表
29. 国际化
30. 歌词复制
31. 歌词源选择器
32. 文件健康检测
33. 播放记忆
34. 插件系统（dart:ffi 动态加载）
35. DSD 解码插件
36. 歌词在线插件

---

## 20. 性能目标

| 指标 | 目标 |
|---|---|
| 冷启动时间 | < 2 秒 |
| 音乐库扫描速度 | > 100 首/秒 |
| 歌词渲染帧率 | ≥ 60 FPS（有特效时） |
| 内存占用（空闲） | < 150 MB |
| 内存占用（播放中） | < 250 MB |
| 安装包体积 | < 50 MB |

### 20.1 大型音乐库渐进降级策略

**原则**：不删除特效，根据曲库规模智能降级，保证流畅度。

| 曲库规模 | 列表渲染 | 歌词特效 | 背景特效 | 优化措施 |
|---|---|---|---|---|
| < 1000 首 | `ListView.builder` | 全特效（模糊/逐字/发光） | 全部启用 | 无特殊优化 |
| 1000-3000 首 | `ListView.builder` + `const` | 减少模糊层数（max 4px） | 保留流体/频谱，禁用粒子 | 增大 `cacheExtent` |
| 3000-5000 首 | 同上 | 禁用模糊，保留渐变 | 仅保留频谱 | 延迟加载封面 |
| 5000+ 首 | 同上 + 虚拟列表 | 基础歌词滚动 | 纯色背景 | 禁用所有动画特效 |

**关键技术**：
- `ListView.builder` 天然懒加载，仅渲染可见项，10000 首歌曲的列表本身不会卡
- 模糊效果（`BackdropFilter`）是性能瓶颈，可通过降低半径或减少叠加层优化
- GLSL 着色器的性能瓶颈是分辨率，不是曲库大小
- 曲库大小影响的是**数据库查询和内存**，不是 UI 渲染
- 封面加载使用 `cached_network_image` 的磁盘缓存 + 占位图策略

---

## 21. 桌面歌词窗口

独立于主窗口的透明浮窗，始终置顶，不在任务栏显示。基于 `desktop_multi_window` + `flutter_acrylic` 实现跨平台透明窗口。

### 21.1 架构

```
主窗口 (Flutter)
    │
    ├── desktop_multi_window → 桌面歌词窗口
    │   ├── windowController.show()
    │   ├── windowController.hide()
    │   ├── windowController.setSize()
    │   └── windowController.setPosition()
    │
    ├── flutter_acrylic → 透明效果
    │   └── Window.setEffect(effect: WindowEffect.transparent)
    │
    └── EventChannel / Isolate ←→ 歌词数据同步
        ├── 当前行文本 + 时间戳
        ├── 下一行预览
        ├── 翻译行
        ├── 播放状态
        └── 样式配置
```

### 21.2 窗口属性

| 属性 | 值 |
|---|---|
| 透明背景 | `flutter_acrylic` → `WindowEffect.transparent` |
| 始终置顶 | `alwaysOnTop: true` |
| 跳过任务栏 | `skipTaskbar: true` |
| 无边框 | `frame: false` |
| 点击穿透 | 锁定模式下启用（Linux: X11 Shape 扩展） |
| 可拖拽 | 通过自定义手势实现（锁定时禁用） |
| 最小尺寸 | 300 × 100 |
| 默认尺寸 | 600 × 200 |

### 21.3 功能

- 双行显示：当前行 + 下一行预览
- 逐字高亮（CustomPainter 渐变扫描效果）
- 控制栏（悬停显示）：播放/暂停、上/下首、锁定、设置、关闭
- 翻译行显示
- 自定义字体、字号、字重
- 自定义已唱/未唱颜色、描边颜色
- 位置和尺寸记忆（跨重启持久化）
- 封面主色自动匹配歌词颜色

### 21.4 渲染流程

```
歌词窗口 (Isolate)
    │
    ├── CustomPainter
    │   ├── 背景：透明 / 封面模糊
    │   ├── 当前行：已唱部分（颜色 A）+ 未唱部分（颜色 B）
    │   ├── 逐字高亮：渐变扫描动画
    │   ├── 下一行：灰色预览
    │   └── 翻译行：小字号灰色
    │
    └── 动画控制器
        ├── 每帧更新进度
        └── 逐字高亮插值
```

### 21.5 交互

- 拖拽移动（锁定时禁用）
- 双击切换主窗口
- 右键菜单：播放控制、关闭
- 悬停 3 秒后自动隐藏控制栏
- 滚轮调节透明度
- 双指缩放调节窗口大小
- 锁定模式：点击穿透，歌词窗口不拦截鼠标事件

### 21.6 跨平台实现

| 平台 | 桌面歌词 | 透明实现 | 点击穿透 |
|---|---|---|---|
| Windows | ✅ | `flutter_acrylic` → DWM 透明 | `WS_EX_TRANSPARENT` |
| macOS | ✅ | `flutter_acrylic` → NSWindow 透明 | `NSWindow.ignoresMouseEvents` |
| Linux X11 | ✅ | `flutter_acrylic` → GTK RGBA Visual | X11 Shape 扩展 |
| Linux Wayland | ✅ | 天然支持透明 | `gtk_widget_set_events` |

**Linux 额外配置**（`linux/my_application.cc`）：

```cpp
// 1. 设置 RGBA Visual 支持透明
gtk_widget_set_visual(
    GTK_WIDGET(window),
    gdk_screen_get_rgba_visual(gdk_screen_get_default())
);

// 2. 移除以下两行（flutter_acrylic 要求）
// gtk_widget_show(GTK_WIDGET(window));
// gtk_widget_show(GTK_WIDGET(view));

// 3. 点击穿透（X11，锁定模式时调用）
#include <X11/extensions/shape.h>
void setClickThrough(GtkWindow* window) {
    GdkWindow* gdk_window = gtk_widget_get_window(GTK_WIDGET(window));
    Display* display = GDK_DISPLAY_XDISPLAY(gdk_window_get_display(gdk_window));
    Window xwindow = GDK_WINDOW_XID(gdk_window);
    Region empty_region = XCreateRegion();
    XShapeSelectInput(display, xwindow, ShapeInput);
    XShapeCombineRegion(display, xwindow, ShapeInput, 0, 0, empty_region, ShapeSet);
    XDestroyRegion(empty_region);
}
```

**桌面环境兼容性**：

| 桌面环境 | 窗口管理器 | 透明 | 模糊 | 说明 |
|---|---|---|---|---|
| KDE Plasma | KWin | ✅ | ✅ | 完整支持 |
| GNOME | Mutter | ✅ | ❌ | 透明可用，无模糊 |
| XFCE | Xfwm | ⚠️ | ❌ | 需开启合成器 |
| Cinnamon | Muffin | ✅ | ❌ | 透明可用 |
| MATE | Marco | ⚠️ | ❌ | 需开启合成器 |
| i3/sway | picom | ✅ | ✅ | 需配置合成器 |

**降级策略**：检测到不支持透明时，桌面歌词降级为不透明窗口（普通浮动窗口模式）。

---

## 22. 任务栏歌词窗口（Windows 专属）

在 Windows 任务栏区域上方显示当前播放歌词。采用**方案 B（覆盖窗口）**，透明窗口浮在任务栏上方，点击穿透。仅支持 Windows。

### 22.1 架构

```
主窗口 (Flutter)
    │
    ├── desktop_multi_window → 任务栏歌词窗口（仅 Windows）
    │   ├── flutter_acrylic → 透明效果
    │   ├── 窗口定位到任务栏区域上方
    │   ├── WS_EX_TRANSPARENT → 点击穿透
    │   └── 监听任务栏变化自动重新定位
    │
    └── EventChannel / Isolate ←→ 歌词数据同步
        ├── 当前行文本
        ├── 已唱/未唱状态
        └── 样式配置
```

**方案 B 原理**：
```
方案 A（嵌入子窗口）：          方案 B（覆盖窗口）← 采用：
┌────────────────────────┐    ┌────────────────────────┐
│ 任务栏                   │    │ 任务栏                   │
│ [开始][搜索][♫歌词][14:32]│    │ [开始][搜索][  空白  ][14:32]│
│   ↑ 歌词嵌入任务栏内部     │    │    ┌──────────────┐     │
└────────────────────────┘    │    │ ♫ 周杰伦 - 晴天 │     │
                               │    └──────────────┘     │
                               │    ↑ 透明窗口浮在任务栏上方│
                               └────────────────────────┘
```

### 22.2 窗口属性（Windows）

| 属性 | 值 |
|---|---|
| 透明背景 | `flutter_acrylic` → `WindowEffect.transparent` |
| 始终置顶 | `alwaysOnTop: true` |
| 跳过任务栏 | `skipTaskbar: true` |
| 无边框 | `frame: false` |
| 点击穿透 | `WS_EX_TRANSPARENT`（不拦截鼠标事件） |
| 窗口大小 | 动态适应任务栏剩余空间 |
| 窗口位置 | 任务栏右侧空白区域（时钟左侧） |

### 22.3 定位策略

```
任务栏布局（Windows 10/11）：

┌─────────────────────────────────────────────────────┐
│  开始 │ 搜索 │ 任务视图 │ pinned apps │ ♫ 歌词 │ 14:32 │
└─────────────────────────────────────────────────────┘
                                    ↑ 歌词窗口定位到这里
```

**定位流程**：
1. 获取任务栏 HWND：`FindWindow("Shell_TrayWnd", null)`
2. 获取任务栏区域：`GetClientRect` + `GetWindowRect`
3. 计算可用空间：任务栏宽度 - 开始按钮 - pinned apps - 系统托盘
4. 窗口定位到可用空间内（居中对齐）
5. 监听任务栏位置变化（`EVENT_OBJECT_LOCATIONCHANGE`）自动重新定位

**Win10 vs Win11 适配**：
- Windows 10：任务栏在底部，歌词窗口定位到右侧
- Windows 11：任务栏居中，歌词窗口定位到时钟左侧空白区域

### 22.4 渲染

```
任务栏歌词窗口 (Isolate)
    │
    ├── CustomPainter
    │   ├── 背景：透明
    │   ├── 歌词文本：单行，已唱（主题色）+ 未唱（灰色）
    │   ├── 字体：跟随系统任务栏字体（Segoe UI）
    │   └── 字号：自动适应任务栏高度（通常 12-14px）
    │
    └── 动画控制器
        └── 文本滚动（歌词过长时水平滚动）
```

### 22.5 交互

- 无交互（纯展示，点击穿透）
- 通过主窗口或托盘菜单控制开关
- 歌词文本不响应鼠标事件

### 22.6 跨平台策略

| 平台 | 任务栏歌词 | 说明 |
|---|---|---|
| Windows 10 | ✅ 覆盖窗口 | 完整支持 |
| Windows 11 | ✅ 覆盖窗口 | 适配新任务栏布局 |
| macOS | ❌ 不支持 | Dock 不支持文本渲染 |
| Linux | ❌ 不支持 | 各桌面环境 Dock 无统一 API |

macOS / Linux 用户通过系统媒体控件（SMTC / MPRIS / Now Playing）获取歌曲信息。

### 22.7 两种歌词窗口同时运行

```
┌─────────────────────────────────────────────────────┐
│                                                      │
│     ┌──────────────────────────────┐                 │
│     │  桌面歌词窗口                 │   ← 浮在桌面    │
│     │  "故事的小黄花"               │     透明背景     │
│     │  "从出生那年就飘着"            │     可拖拽       │
│     └──────────────────────────────┘     可锁定       │
│                                                      │
│                                                      │
├──────────────────────────────────────────────────────┤
│  开始 │ 搜索 │ 🎵 Still │ ♫ 周杰伦 - 晴天 │ 14:32 │
│        │      │              │ ↑ 任务栏歌词窗口 ↑      │
└──────────────────────────────────────────────────────┘
```

两个窗口独立运行，共享同一份歌词数据：
- 桌面歌词：完整功能（逐字动画、双行、翻译、封面），**跨平台**
- 任务栏歌词：简化版（单行文本、已唱/未唱颜色、滚动），**仅 Windows**

### 22.8 方案 B 利弊

| 优点 | 缺点 |
|---|---|
| 实现简单（透明窗口 + 定位） | 不是原生嵌入，视觉上可区分 |
| Windows 11 兼容性好 | 全屏应用时任务栏歌词不可见（预期行为） |
| Explorer 崩溃不影响歌词窗口 | 需要监听任务栏位置变化 |
| 不与 TranslucentTB 等工具冲突 | |
| 维护成本低 | |

### 22.8 窗口间通信

```
主窗口 (Flutter Main Isolate)
    │
    ├── EventChannel → 桌面歌词窗口
    │   ├── 歌词行数据
    │   ├── 播放状态
    │   └── 样式配置
    │
    └── EventChannel → 任务栏歌词窗口
        ├── 歌词行数据
        ├── 播放状态
        └── 样式配置

通信协议：
- MethodChannel：控制命令（show / hide / update）
- EventChannel：持续数据流（歌词进度、播放状态）
```

---

## 23. 系统集成

### 23.1 系统托盘

- 最小化到托盘（关闭窗口时）
- 托盘菜单：显示窗口、播放控制（播放/暂停/上/下首）、桌面歌词开关、任务栏歌词开关、退出
- 悬停提示：当前播放歌曲名
- 图标跟随播放状态变化

### 23.2 任务栏集成（Windows）

- 任务栏缩略图按钮：上一首 / 播放暂停 / 下一首
- 任务栏进度条：同步播放进度
- 窗口标题：实时显示 `"歌曲名 - 艺术家 | Still"`

### 23.3 媒体会话

- 集成 OS 媒体控件（Windows SMTC / macOS Now Playing / Linux MPRIS）
- 显示歌曲信息、封面、时长
- 支持播放/暂停、上/下首、seek

---

## 24. 封面管理

### 24.1 封面发现

自动扫描优先级：
```
内嵌封面 → 同目录 cover.jpg → front.jpg → album.jpg → artwork.jpg → folder.jpg → folder.png
```

### 24.2 封面缓存

- 提取的封面存储到应用缓存目录
- 文件名：SHA256(文件路径) + 原始扩展名
- 缓存大小限制：可配置（默认 500MB）
- 支持手动清除缓存

### 24.3 封面主色提取

- 从封面提取主色调（`palette_generator` 包）
- 用于：
  - 歌词界面背景渐变
  - 主题色自动匹配（可选）
  - 歌曲信息卡片背景色

---

## 25. 播放队列

### 25.1 队列管理

- 独立于歌单，临时播放序列
- 支持拖拽排序
- 支持从队列移除歌曲
- 支持清空队列
- 队列持久化（跨重启保留）

### 25.2 队列面板

- 从底部播放栏右侧按钮展开
- 侧滑面板（从右侧滑入，300ms）
- 显示当前队列歌曲列表
- 支持搜索队列内的歌曲
- 当前播放项高亮

---

## 26. 歌词复制

- 选中歌词行可复制
- 复制选项：
  - 仅原文
  - 原文 + 翻译
  - 原文 + 翻译 + 歌曲信息
- 复制到剪贴板，带格式

---

## 27. 歌词源选择器

- 每首歌可切换歌词来源：
  - 内嵌歌词（歌曲文件内嵌）
  - 本地 LRC 文件
- 歌词源选择器弹窗显示可用来源
- 选择结果持久化

---

## 28. 文件健康检测

- 扫描时自动检测：
  - 文件是否可读
  - 文件路径是否有效
  - 元数据是否完整
- 不可读文件列表：显示在设置页面
- 支持重链（重新指定文件路径）
- 支持批量移除无效文件

---

## 29. 自定义滚动条

- 隐藏原生滚动条
- 自绘滚动条拖拽指示器
- 拖拽时显示字母气泡（A-Z 快速定位）
- 滚动条宽度：6px（悬停时 8px）
- 滚动条颜色：跟随主题色
- 平滑滚动动画

---

## 30. 播放记忆

- 记住每首歌的播放位置（跨重启）
- 重新播放时从上次位置继续
- 支持关闭此功能
- 位置数据存储在数据库中

---

## 31. 键盘快捷键

| 快捷键 | 功能 |
|---|---|
| Space | 播放/暂停 |
| Left/Right | 快退/快进 5 秒 |
| Up/Down | 上一首/下一首 |
| Ctrl+↑ | 音量增加 5% |
| Ctrl+↓ | 音量减少 5% |
| Ctrl+M | 静音切换 |
| F11 | 全屏切换 |
| Ctrl+F | 搜索 |
| Ctrl+L | 歌词全屏 |
| Ctrl+T | 翻译开关 |
| Escape | 关闭歌词/退出全屏 |

---

## 32. 插件化架构

### 32.1 插件系统设计

Still 采用插件化架构，支持运行时动态加载功能模块。插件以动态库（`.dll` / `.so` / `.dylib`）形式分发，通过 `dart:ffi` 加载。

```
┌─────────────────────────────────────────────────────────┐
│  Still 主应用                                            │
│                                                          │
│  插件管理器 (PluginManager)                               │
│  ├── 扫描 plugins/ 目录                                  │
│  ├── 加载插件动态库                                       │
│  ├── 调用插件初始化接口                                   │
│  ├── 管理插件生命周期                                     │
│  └── 提供插件间通信机制                                   │
│                                                          │
│  插件接口 (Plugin Interface)                              │
│  ├── onInit()：初始化                                    │
│  ├── onDispose()：销毁                                   │
│  ├── getName()：插件名称                                  │
│  ├── getVersion()：版本号                                 │
│  └── getCapabilities()：能力声明                          │
└─────────────────────────────────────────────────────────┘
```

### 32.2 插件类型

| 类型 | 说明 | 示例 |
|---|---|---|
| 解码插件 | 扩展音频格式支持 | DSD 解码插件 |
| 歌词插件 | 歌词在线搜索/下载 | 歌词在线插件 |
| 音效插件 | 音频后处理 | 空间音效插件 |
| 可视化插件 | 频谱/波形可视化 | 3D 频谱插件 |
| 导出插件 | 音频格式转换 | 批量转码插件 |

### 32.3 DSD 解码插件

DSD（Direct Stream Digital）格式通过插件支持，不增加主应用体积。

```
DSD 解码插件 (dsd_decoder.dll)
    │
    ├── 接口
    │   ├── dsd_init()：初始化解码器
    │   ├── dsd_decode(file_path, output_buffer)：解码 DSD 数据
    │   ├── dsd_get_info(file_path)：获取 DSD 文件信息
    │   └── dsd_dispose()：释放资源
    │
    ├── 支持格式
    │   ├── DSF（DSD Stream File）
    │   ├── DFF（DSD IntExchange File）
    │   └── ISO DSD（ISO模式）
    │
    └── 实现
        ├── 基于 miniaudio Node Graph
        ├── DSD → PCM 转换
        └── 支持 DSD64 / DSD128 / DSD256
```

**集成方式**：
```dart
// 主应用检测到 DSD 文件时
if (file.extension == 'dsf' || file.extension == 'dff') {
  final plugin = pluginManager.getPlugin('dsd_decoder');
  if (plugin != null) {
    // 使用 DSD 插件解码
    final pcmData = plugin.decode(file.path);
    // 送入 miniaudio Node Graph 播放
  } else {
    // 提示用户安装 DSD 解码插件
    showPluginInstallPrompt('dsd_decoder');
  }
}
```

### 32.4 歌词在线插件

歌词在线搜索和下载通过插件实现，支持多个歌词源。

```
歌词在线插件 (lyrics_online.dll)
    │
    ├── 接口
    │   ├── lyrics_init()：初始化
    │   ├── lyrics_search(artist, title)：搜索歌词
    │   ├── lyrics_fetch(lyric_id)：获取歌词内容
    │   ├── lyrics_get_sources()：获取可用歌词源列表
    │   └── lyrics_dispose()：释放资源
    │
    ├── 支持歌词源
    │   ├── 网易云音乐
    │   ├── QQ 音乐
    │   ├── 酷狗音乐
    │   ├── 自定义歌词源（用户配置 API）
    │   └── ...（可扩展）
    │
    └── 特性
        ├── 并发搜索多个歌词源
        ├── 歌词质量评分
        ├── 自动匹配最佳歌词
        └── 缓存已下载歌词
```

**集成方式**：
```dart
// 用户点击"在线搜索歌词"时
final plugin = pluginManager.getPlugin('lyrics_online');
if (plugin != null) {
  final results = await plugin.search(artist: '周杰伦', title: '晴天');
  // 显示搜索结果列表
  // 用户选择后下载并应用
}
```

### 32.5 插件安装与管理

```
设置页面 → 插件管理
    │
    ├── 已安装插件列表
    │   ├── 插件名称 + 版本
    │   ├── 启用/禁用开关
    │   ├── 卸载按钮
    │   └── 更新检查
    │
    ├── 插件商店（可选）
    │   ├── 浏览可用插件
    │   ├── 一键安装
    │   └── 评分和评论
    │
    └── 手动安装
        ├── 选择本地 .dll / .so / .dylib 文件
        └── 验证签名（可选）
```

### 32.6 插件目录结构

```
com.still.app/
├── plugins/
│   ├── dsd_decoder/
│   │   ├── dsd_decoder.dll (Windows)
│   │   ├── libdsd_decoder.so (Linux)
│   │   ├── libdsd_decoder.dylib (macOS)
│   │   └── plugin.json (元数据)
│   └── lyrics_online/
│       ├── lyrics_online.dll
│       ├── liblyrics_online.so
│       ├── liblyrics_online.dylib
│       └── plugin.json
```

### 32.7 插件安全

- 插件运行在主应用进程内（无沙箱）
- 插件可访问主应用的内存空间
- 建议：仅加载可信来源的插件
- 可选：插件签名验证（RSA-2048）
- 可选：插件权限声明（网络访问、文件系统访问）

---

*文档结束*
