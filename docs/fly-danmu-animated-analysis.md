# 飞行弹幕动图无法动：原因与解决办法

分支：`feat/fly-danmu-image-animated`（基于 `c0932e89`）

## 现象

聊天列表里的 GIF/动效表情能正常播放动画，但**飞行弹幕层**（横向飞过屏幕的弹幕）里的同一张 GIF/动图只显示第一帧，不播放。

## 根因（带代码证据）

飞行弹幕的渲染架构是「**一次性录制成静态位图 `ui.Picture`，之后每帧平移 `drawPicture`**」，从架构到解码两层都不支持逐帧动画：

1. **解码层只取第一帧**
   `apps/pure_live/lib/shared/danmaku/danmaku_overlay.dart` 的 `_EmoteImages`：
   - `_load`（`danmaku_overlay.dart:1175-1210`）用 `ResizeImage(provider, height: 96).resolve(...)`（1178 行）+ 单次 `ImageStreamListener`（1194 行），回调里 `info.image.clone()`（1196 行）只取当前那一帧（对动画流即第一帧），随后 `stream.removeListener` 不再监听后续帧。
   - 缓存类型 `Map<String, ui.Image?>`（`danmaku_overlay.dart:1144`）只存单张静态位图，无法表达帧序列。
   - `ResizeImage` 本身对动画流只会缩放/重解码当前帧，丢掉 `isAnimated` 的后续帧。

2. **渲染层冻结成位图**
   - `_record`（`danmaku_overlay.dart:732-803`）把整条弹幕（文本 + 表情图）画进一个 `ui.PictureRecorder`，`recorder.endRecording()`（802 行）得到**一张静态 `ui.Picture`**；表情图在那一刻被 `drawImageRect` 冻结成单帧（792-798 行）。
   - `_Flying`（`danmaku_overlay.dart:1221-1249`）只持有 `_Rendered`（一张 `ui.Picture`）。
   - `_DanmakuPainter._draw`（`danmaku_overlay.dart:1304-1312`）每帧 `canvas.drawPicture(item.picture.picture)`（1310 行）——永远画同一张位图，没有帧切换。

3. **为什么聊天列表能动、飞行弹幕不能**
   聊天列表（`apps/pure_live/lib/features/live_play/danmaku/chat_list.dart:1055`）用 `Image` + `gaplessPlayback: true` + `frameBuilder`，Flutter 对 `isAnimated` 流自动逐帧播放；礼物行（`gift_line.dart:308`）、竖屏聊天栈（`portrait_chat_overlay.dart` 用 `EmoteText`）同理。**飞行弹幕绕过了 `Image` widget，直接走 Canvas + `ui.Picture`，丢掉了动画帧流。**

   这也是 3.x 基线（`flame_barrage` 静态表情图集）的延续：飞行弹幕本来就没有动图概念。

## 解决办法

### 方案 A（推荐，改动可控）：动画表情走独立 widget 层，静态表情继续走 Canvas

核心思路：**让"是否动画"成为分流依据**，把动画表情从 Canvas 录制路径里拆出来。

1. **识别动画图**
   - 在 `ChatEmoteSegment` 加一个 `isAnimated`（或按 url 扩展名 `.gif`/`webp` 嗅探；最可靠是解码后看 `info.image.isAnimated`）。
   - `_EmoteImages` 对动画图**不再**用 `ResizeImage`+取首帧，而是保留完整动画 `ImageStream`/缓存 `AnimatedImage` 所需数据。

2. **飞行弹幕层分两条渲染路径**
   - 静态表情 + 文本：维持现状（`_record` → `ui.Picture` → `drawPicture`）。
   - 动画表情：在 `DanmakuOverlay` 的 `Stack` 里加一个 `Positioned` 子层，用 `AnimatedImage`（或 `Image(gaplessPlayback: true, frameBuilder: ...)`）渲染该表情，**位置跟随所属弹幕 lane 的同一套 clock 平移**（`item.left(clock, width)` 计算 x，`item.y` 计算 y）。
   - 即：动画表情"骑"在飞行弹幕上，但用 widget 动画而非 Canvas 位图。

3. **同步平移**
   - 动画表情 widget 的 x 坐标必须和它的弹幕 lane 用同一个 `state._clockOf(item)` / `item.left(...)`（`danmaku_overlay.dart:1305`），否则表情和文本会错位。
   - 用 `AnimatedBuilder`/`Ticker` 跟随 `_DanmakuPainter` 的同一帧时钟即可。

代价：动画表情脱离 Canvas 统一绘制，多一层 widget；需要保证与 lane 的时钟同步。但改动集中在 `danmaku_overlay.dart` + `ChatEmoteSegment`，不影响静态弹幕和聊天列表。

### 方案 B（最简，降级/降级+提示）

- 维持现状（飞行弹幕里 GIF 显示首帧），在文档/设置里标注"飞行弹幕的表情仅显示静态首帧，动画请看聊天列表"。
- 改动量最小，但用户体验上"动图不动"。

### 方案 C（激进，重构）

把飞行弹幕的表情整体改用 `RepaintBoundary` + `Image` widget 混合绘制（文本走 Canvas、表情走 widget overlay），彻底支持所有动图。改动最大，回归面宽。

## 实现（本分支 `feat/fly-danmu-image-animated` 已落地）

采用**方案 2 的变体**：不按消息预合成 N 张 picture，也不给每条弹幕挂 `AnimatedImage` 控件；而是在 `_EmoteImages` 里把动画表情**抽帧成 `_EmoteFrames`（`List<ui.Image>` + 每帧周期，url 级 LRU 共享、容量 64）**。`_record` 把**静态表情和文字**仍录进一张 `ui.Picture`，**动画表情**只记一个 `_AnimatedSlot`（x 偏移 + 帧序列引用）；`_DanmakuPainter._draw` 每 display 帧按共享钟 `elapsedMs ~/ frameDurationMs % frameCount` 给每个动画表情选帧，各自按自身周期播放。

- 抽帧字节：网络表情走 `AppImageCache.manager.getFileFromCache` / `downloadFile(url, authHeaders:)` 拿磁盘 bytes → `ui.instantiateImageCodec(bytes, targetHeight: 96)`；打包 asset 走单帧（不抽帧）。
- 静态路径完全不变（单帧 `frames.length == 1` → `animated == false` → 仍走原 `drawPicture`）。
- 聊天列表/礼物/头像不动。

## 涉及文件

- `apps/pure_live/lib/shared/danmaku/danmaku_overlay.dart`（新增 `_EmoteFrames`/`_AnimatedSlot`；`_EmoteImages` 抽帧 + LRU 64；`_record` 分离静态/动画；`_Rendered.animatedSlots`；`_DanmakuPainter._draw` 逐帧选帧）
- 参考：`apps/pure_live/lib/features/live_play/danmaku/chat_list.dart:1055`、`gift_line.dart:308`（`gaplessPlayback` + `frameBuilder` 写法）

> 未引入 `ChatEmoteSegment.isAnimated` 字段：帧数在抽帧时由 `codec.frameCount` 判定，无需改模型。

