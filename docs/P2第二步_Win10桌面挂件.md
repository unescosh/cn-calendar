# P2 第 2 步：Win10 桌面挂件（2026-11-11 15:17）

> 用户「先做WIN10桌面挂件」。按「一次只改一件事」，本步只做 Win10 桌面挂件，
> 不碰任务栏时间接管、不开 UOS Dock 插件、不做托盘月历、不换 FFI。
> 关联：`docs/P2桌面形态方案.md`、`docs/P2第一步_Win10托盘与时间接管.md`、
> `docs/资源占用规范.md`。

## 一、目标与边界

用户 4 条需求里的第 2 条还差最后一块：「返回桌面后就能看见日历情况」。
第 1 步交付的托盘常驻只是入口，桌面上没有可视内容。本步补一个
**透明、置底、只读、随开机自启的整月挂件**。

| 项 | 口径 |
|---|---|
| 平台 | **仅 Win10**。UOS 正式包产物一个字节不变，不用重装 / 重验 |
| 数据 | 四层数据、Rust 核心、CLI JSON 契约、月历配色全部零改动 |
| 主界面 | 整屏推入动画、黑白主题、节日正日语义、双标签一个字不动 |
| CI 工作流 | `.github/workflows/main.yml` **一字不改**（见第二节） |
| 关闭方式 | 托盘右键菜单新增「桌面挂件」勾选开关，写 `HKCU\Software\CNCalendar\WidgetEnabled` |
| 不做 | 账号、联网同步、遥测、第二常驻进程、后台定时器、周期轮询 |

## 二、为什么不碰 Flutter embedder C++ API

CI 每次用 `flutter create --platforms=windows .` 动态生成 runner，
P2 第 1 步靠 `apply_p2_patch.ps1` 往模板里精确插 4 处并追加 1 个 `.cpp`。
本机没有 MSVC / Flutter / Dart 工具链，任何需要猜 Flutter C++ 头文件的
写法（插件注册表、`MethodChannel<T>`、`BinaryMessenger`）都只能靠 CI 试错。

本步改用**单向文件 + 窗口消息**，全程只用标准 Win32 / GDI 与 `dart:ffi`：

```
Dart  (启动 / 回到当月 / L4 更新 / 主题切换 / 跨天)
  └─ ui.PictureRecorder 离屏画整月 → toImage → rawRgba → BGRA
     → 写 %USERPROFILE%\.cn_calendar\cache\widget_image.bin（写完才通知）
     → dart:ffi  PostMessageW(widget_hwnd, WM_APP+5, 0, 0)
原生  (主线程已有的 GetMessage 循环)
  └─ WidgetWndProc 收到 WM_APP+5 → 读位图 → CreateDIBSection
     → SetWindowPos(HWND_BOTTOM) → InvalidateRect → WM_PAINT BitBlt
```

因此：

- **不新增 runner 源文件、不改补丁脚本、不改 `main.yml`**。挂件代码直接
  扩写进已有的 `cn_calendar_p2.cpp`，补丁脚本只是把这两个文件复制过去，
  内容变了但脚本不用动。网页「全选覆盖上传」再次漏掉隐藏 `.github`
  也不会造成任何后果 —— 这正是上一轮踩坑后刻意选的形态。
- **不新增进程、不新增线程、不新增定时器**。挂件窗口创建在 `wWinMain`
  主线程，消息由现有的 `while (::GetMessage(...))` 分发；托盘线程仍是唯一
  额外线程，与第 1 步完全一致。
- 原生层**不解析 JSON、不画文字、不装字体、不重写一遍月历**，只做贴图，
  配色 / 标签 / 休班角标 / 今天高亮全部由 Dart 侧同一套 `CalendarPalette`
  与 `DayInfo` 生成，挂件与主窗口天然一致。

## 三、契约（两侧必须一致，已由源码级测试锁死）

| 契约 | 值 |
|---|---|
| 位图魔数 | `0x47475743`（`CWWG`），小端 DWORD |
| 位图头 | 16 字节：magic / width / height / reserved |
| 像素 | `width*height*4` 字节 BGRA，自上而下；**alpha 恒 255** |
| 窗口消息 | `WM_APP + 5` = `0x8005`（Dart → 挂件刷新） |
| 托盘消息 | `WM_APP + 6`（托盘菜单 → 挂件显隐） |
| HWND 文件 | `widget_hwnd.txt`，十六进制文本，Dart `int.tryParse(radix: 16)` |
| 位图文件 | `widget_image.bin` |
| 排障文件 | `widget_status.txt`，每次发布写一行 `时间 \| start \| render-ok \| rgba-ok \| bitmap-ok \| hwnd=… \| posted`；失败时写 `error:…` |
| 目录 | `cachePath()`：优先 `CN_CAL_CACHE_DIR`，否则 `%USERPROFILE%\.cn_calendar\cache`；**两侧都必须显式用路径字符串拼接** |
| 配色 | `main.dart` 把 `CalendarPalette` 的 18 个 ARGB 值按固定顺序传入，单一来源 |

alpha 恒 255 是关键：画布第一步就铺满**不透明**底色，整体半透明由
`SetLayeredWindowAttributes(..., 216, LWA_ALPHA)` 统一处理。这样既不需要
premultiply，也不受 `rawRgba` 在不同 Flutter 版本上是否预乘的影响。

## 四、窗口形态与兜底

```
WS_EX_LAYERED | WS_EX_NOACTIVATE | WS_EX_TRANSPARENT | WS_EX_TOOLWINDOW
WS_POPUP + HWND_BOTTOM，位置取 SPI_GETWORKAREA 右下角，留 24px 边距
```

- `NOACTIVATE`：不抢焦点，不打断办公软件；
- `TRANSPARENT`：鼠标穿透，桌面图标照常可点，挂件只读不交互；
- `TOOLWINDOW`：不进任务栏、不在 Alt+Tab 里出现；
- `HWND_BOTTOM`：置底，其它窗口盖住它，返回桌面才看见；
- `LWA_ALPHA=216`（约 85% 不透明）：壁纸能透出来，文字仍清晰。

**兜底**：桌面挂件是纯增强能力。窗口类注册失败、位图文件缺失、字体缺失、
HWND 文件读不到、Dart FFI 加载失败，`publish()` 一律静默降级，主界面与
托盘完全不受影响；启动时挂件窗口无内容就是全透明，不会留下黑块。
托盘菜单可随时关掉挂件，开关持久化到注册表，重启后保持。

## 五、刷新时机与低资源口径

| 时机 | 动作 |
|---|---|
| 启动首屏数据就绪 | 发布一次当月位图 |
| 回到当月 / L4 调休更新后重取当月 | 发布一次 |
| 用户翻到别的月份 | **不发布**（避免滚轮连翻反复生成位图） |
| 黑白主题切换 | 发布一次（挂件跟着换色） |
| 跨天 / 跨月 / 跨年 / 时钟回拨 | 日期哨兵触发，发布一次当月 |

**日期哨兵**是本步唯一新增的周期性动作：`Timer.periodic` 每 30 分钟
只比较一次「年-月-日」字符串，日期没变零动作；日期变化才重新取当月
（命中 `MonthCache`，不启动 CLI 进程）并重画一次位图。不联网、不重绘
主窗口、不常驻动画、不读磁盘（除当月数据已在内存）。一天最多一次实际
重绘，符合用户「更新别太频繁、定期校准但保精准」的要求。
跨月时若不刷新，挂件会停在上个月的格子上，所以这个哨兵不能省。

静止状态：窗口没有 `WM_PAINT`、没有 `SetTimer`、没有联网、没有第二个
进程；托盘线程仍阻塞在 `GetMessage`。内存里只多一张 448×424×4 ≈ 763 KB
的 DIB，且只在刷新那一刻重建。

## 六、验收方式（用户侧，不用装任何工具）

1. 下载新的 `cn-calendar-windows-portable`，**退出正在运行的旧版**后完整覆盖到
   `%LOCALAPPDATA%\CNCalendar\`（自启项路径不变，不用重设）。
2. 双击打开：右下角托盘出现日历图标；**返回桌面**（Win+D 或最小化所有窗口）
   应看到一块半透明整月月历，位置在右下角、不遮桌面图标操作。
3. 挂件内容：标题年月、周日起至周六、9/30 烈士纪念日、休/班角标、
   周末橙红数字、四类配色、今天高亮，与主窗口一致。
4. 点挂件所在位置 → 鼠标穿透到桌面，不抢焦点、不弹菜单。
5. 切换黑白主题 → 挂件颜色跟着变；滚轮翻月 → 挂件**保持系统当月**，不跟着翻。
6. 右键托盘 → 菜单里有「桌面挂件」勾选；取消勾选 → 挂件消失；再勾回来 → 挂件回来。
7. 点任务栏时间弹出的本软件月历、X 隐藏托盘、单实例等第 1 步的 6 条**无退化**。
8. 右键托盘 →「退出」→ 挂件与托盘图标一起消失，任务管理器里仍只有
   一个 `cn_calendar.exe`、退出后 0 个残留进程。

## 七、本机已验证 / 只认 CI 与实机

**本机已实跑**：

- `apply_p2_patch.ps1` 用 Flutter 3.22 官方模板（含 CRLF 转换）完整模拟
  `flutter create` + 打补丁，4 处插入、CMake 追加、幂等保护全部通过，
  复制进 runner 的 cpp/h 是新版本；
- 三个 P2 源文件纯 ASCII，C++ 括号平衡、函数定义顺序、92 个 Win32/GDI
  调用名逐一核对，无 STL / lambda / 异常 / 新线程 / 定时器；
- Dart 侧括号平衡、**34 个测试**计数、源码契约静态重放全通过；
- Rust 37 测试、`verify_data.py` 2311 项照常通过；
- **Win10 实机已验证原生链路**：进程起来后 `widget_hwnd.txt` 有值，
  `EnumWindows` 能枚举到 `CNCalendar_WidgetHost`（可见、右下角
  448×424）；往缓存写一张合成 BGRA 位图并 `SendMessageW(WM_APP+5)`，
  桌面右下角立刻出现该卡片。窗口创建、`HWND_BOTTOM` 的 Z 序、
  `CreateDIBSection` + `BitBlt`、`LWA_ALPHA` 全部工作正常。

**只认 CI run**：C++ 实际编译 / 链接（尤其 `gdi32.lib`、`user32.lib` 是否
由 MSVC 默认库带入，run #14 之后的新一轮要复核）、`dart:ffi` 在 Windows
runner 上加载 `user32.dll`、`ui.PictureRecorder` 离屏渲染与中文字体、
`rawRgba` 通道顺序、托盘菜单开关的真实行为。
本机无 MSVC / Flutter / Dart，不得说「应该能编过」。

## 八、遗留与风险

- `HWND_BOTTOM` 依赖 Windows Z 序。2026-11-13 已用合成位图在本机实机
  验证：挂件确实显示在桌面右下角、位于壁纸之上、被其它窗口正常盖住，
  因此**不需要**升级为 `SetParent` 到桌面 `WorkerW`（需 `0x052C`
  未公开消息 + `EnumWindows`）。仅保留「Win10 大版本更新后再回归」提醒。
- 挂件固定 448×424 逻辑像素，未做高 DPI 缩放；高缩放率屏幕上会偏小。
- 32bpp DIB 用 `BI_RGB`，GDI 忽略像素 alpha，整体半透明只能靠 `LWA_ALPHA`，
  所以做不到「卡片背景半透明而文字完全不透明」的磨砂效果。
- 双端 24 小时资源曲线、Win10 GUI 资源采样仍未量；桌面挂件上线后应补测。
- UOS 侧 Dock 插件 ABI 代际（`dde-dock` / `dde-shell`）仍待实机探测。

## 九、第一次实机失败与修复（2026-11-13）

**现象**：用户「没有挂件」。桌面截图只有壁纸和图标，主窗口能正常打开。

**排查证据**（本机直接读文件 / 枚举窗口，未改用户数据）：

| 检查项 | 结果 | 结论 |
|---|---|---|
| `%LOCALAPPDATA%\CNCalendar\cn_calendar.exe` | 101,376 字节、`data\app.so` 4,277,168 字节，与解压目录逐字节一致 | 新 exe 与新 Dart 快照都装上了 |
| `app.so` 字符串 | 含 `widget_image.bin` / `widget_hwnd.txt` / `PostMessageW` / `DesktopWidget` | 新 Dart 代码确实进了产物 |
| `.cn_calendar\cache\widget_hwnd.txt` | 存在，`'6803DA'` | 原生 `InitWidget()` 创建了窗口 |
| `.cn_calendar\cache\widget_image.bin` | **不存在**（全盘常见目录搜索也只有 HWND 文件） | Dart 位图发布根本没落盘 |
| `EnumWindows` | `CNCalendar_WidgetHost` vis=True rect(1383,632,1831,1056) | 窗口在，只是没有图可贴 |
| 合成位图 + `SendMessageW(0x8005)` | 桌面右下角立即出现卡片 | 原生贴图链路与 Z 序完全正常 |

**根因**：`desktop_widget.dart` 里写成了
`File('$dir$sep$imageFileName')`，其中 `dir` 是 `Directory` 对象。
`dart:io` 的 `_Directory.toString()` 实现是

```dart
String toString() => "Directory: '$path'";
```

所以实际拼出的文件名是
`Directory: 'C:\Users\...\cache'\widget_image.bin`，含冒号，在 Windows
上是非法路径。`writeAsBytesSync` 抛 `FileSystemException`，被 `publish()`
的 `catch (_)` 静默吞掉——**窗口建好了、位图永远不出现、挂件全透明**。
这与字体、权限、杀软、DPI、Flutter 版本都无关，纯属路径拼接。

**修复清单**：

1. `app/lib/desktop_widget.dart`：显式用
   `File('${dir.path}${Platform.pathSeparator}$imageFileName')`；
   新增 `widget_status.txt`，每次发布留一行 `start | render-ok |
   rgba-ok | bitmap-ok | hwnd=… | posted`，异常写 `error:类型 内容`，
   用户把这个小文件发回来即可定位，不用装任何开发工具；
   HWND 短重试由 6×250ms 放宽到 12×250ms（3 秒封顶）。
2. `packaging/p2/windows/cn_calendar_p2.cpp`：`InitWidget()` 写完
   `widget_hwnd.txt` 后自己 `PostMessageW(g_widget, kMsgRefreshWidget)`，
   兜住「Dart 先写位图、没等到 HWND」的竞态；不新增线程 / 定时器。
3. `app/test/widget_test.dart`：新增一条路径契约回归测试，锁死
   「禁止把 `Directory` 对象插进字符串」「必须出现 `dir.path`」
   「必须有状态文件」「原生必须补一次刷新」。Dart 测试 33 → **34**。
4. `main.yml` 与 `apply_p2_patch.ps1` **仍然一字不改**，全选覆盖上传即可。

**本机复验口径**：Rust 37 测试、`verify_data.py` 2311 项、Dart 词法括号
平衡与 34 个测试计数、新增断言静态重放 5/5、原生链路实机贴图成功。
Dart 实际运行、C++ 重新编译、挂件显示真实月历仍只认下一轮 CI run +
用户 Win10 实机截图。
