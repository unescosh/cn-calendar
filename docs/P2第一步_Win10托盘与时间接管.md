# P2 第 1 步：Win10 托盘常驻 + 接管任务栏时间（2026-11-10 16:40）

> 用户指令「开始做P2」。按 `docs/P2桌面形态方案.md` 第五节「一次只改一件事」，
> 本轮**只做 Win10 侧的需求 1 与托盘常驻**；桌面挂件、UOS Dock 插件、
> FFI 桥接仍为后续步骤。**UOS 正式版产物一个字节都没变，不需要重装、不需要重验。**

## 一、这一版实际做到了什么

| 用户要求 | 本步结果 |
|---|---|
| 点任务栏时间弹出的界面就是本软件界面 | Win10 已实现：识别时钟区域点击 → 弹出**同一个 Flutter 月历窗口** |
| 常驻后台 | 关闭按钮改为隐藏到托盘，进程常驻；托盘右键「退出」才真正结束 |
| 开机自启 | 托盘菜单里可直接开关，与 `enable-autostart.bat` 是同一个 `HKCU\...\Run` 项 |
| 不能影响精确性 | 数据层、CLI、JSON 契约、联网核对、切月动画**零改动** |
| 低资源 | 全部在主进程内，无第二常驻进程、无后台定时器、无轮询 |

明确不做：不修改 / 禁用 / 注入系统组件，不写系统目录，不做驱动，不装 DLL 注入钩子，
不上报遥测，不改系统自带时间插件的配置。

## 二、为什么用「runner 补丁」而不是提交 runner 目录

CI 里 Windows 平台壳是每次 `flutter create --platforms=windows .` **动态生成**的
（`app/windows/` 不在仓库里）。直接提交整份 runner 会让 CMake/Flutter 胶水与
Flutter 3.22 版本强绑定，升级时容易碎。

因此新增 `packaging/p2/windows/` 三个文件，由 `apply_p2_patch.ps1` 在
`flutter create` 之后、`flutter build windows` 之前：

1. 复制 `cn_calendar_p2.cpp` / `.h` 进 `app/windows/runner/`；
2. 往 `CMakeLists.txt` 的源文件表追加一行 `"cn_calendar_p2.cpp"`，
   追加 `shell32.lib` / `advapi32.lib`，并给**这一个**源文件设 `/W3;/WX-`
   （Flutter 对 runner 开了 `/WX`，不让新文件的警告升级成构建失败）；
3. 往 `main.cpp` 精确插入 4 处字符串（见下表）；
4. 逐处 `Assert-Contains` 自检，模板一旦变化就明确报错，
   **不会静默产出「没打上补丁」的 exe**；并有防重复打补丁的幂等保护。

| # | 插入点 | 作用 |
|---|---|---|
| 1 | `#include "utils.h"` 之后 | `#include "cn_calendar_p2.h"` |
| 2 | `flutter::DartProject project(L"data");` 之前 | 单实例检测；已有实例则唤起它并直接 `return` |
| 3 | `window.SetQuitOnClose(true);` 之后 | 绑定 HWND、子类化窗口、起托盘线程与钩子 |
| 4 | `::CoUninitialize();` 之前 | 卸载钩子、删托盘图标、清理注册表 HWND |

编码口径：`apply_p2_patch.ps1` 用 `UTF8Encoding($false)` 写回（PowerShell 5.1
的 `Set-Content` 默认 UTF-16，会毁掉 CMake / C++ 输入文件），并先把 CRLF
统一成 LF 再匹配（GitHub checkout 在 Windows 上会转 CRLF）。
三个新文件均为**纯 ASCII**，中文界面文案用 `\uXXXX` 转义，
避开 MSVC 默认代码页。

## 三、原生模块结构（`cn_calendar_p2.cpp`）

单进程，两处线程：主线程（Flutter 窗口 + Dart UI）与一个托盘线程。

- **单实例**：命名 Mutex `Local\CNCalendar_SingleInstance_Mutex`。
  第二个进程启动时从 `HKCU\Software\CNCalendar\MainWindowHwnd` 读出第一个
  窗口的 HWND，`PostMessage` 把它叫到前面，然后自己退出。
  不新开窗口、不多一个进程。
- **窗口子类化**：`SetWindowLongPtrW(GWLP_WNDPROC)` 拦截 `WM_CLOSE`
  → `ShowWindow(SW_HIDE)`；其余消息 `CallWindowProcW` 原样转发给 Flutter。
  自定义 `WM_APP+1` 显示、`WM_APP+2` 真正退出。
- **托盘**：隐藏的顶层宿主窗口（故意不用 `HWND_MESSAGE`，这样能收到
  `TaskbarCreated` 广播，Explorer 重启后自动补回图标）+ `Shell_NotifyIconW`。
  左键显示/隐藏月历；右键菜单：打开/隐藏月历、接管任务栏时间（勾选）、
  开机自启（勾选）、退出。
- **任务栏时间接管**：`SetWindowsHookExW(WH_MOUSE_LL)`，回调里
  `WindowFromPoint` 向上遍历 5 层取类名，命中 Win10 的 `TrayClockWClass`
  时吞掉这次按下与抬起，并 `PostMessage` 给托盘宿主显示月历窗口。
  `WH_MOUSE_LL` 不向其他进程注入 DLL，回调只在本进程托盘线程执行。
- **开关持久化**：`HKCU\Software\CNCalendar\HookTaskbarClock`（默认 1）。
  关闭后钩子仍在但不再吞点击，系统日历照常弹，托盘入口不受影响。

低资源口径：钩子只在真实鼠标事件时被回调，托盘只被动等消息，
静止时没有 vsync 回调、没有定时器、没有周期联网，
符合 `docs/资源占用规范.md` 的 P2 硬约束。

## 四、风险、兜底与已知边界

| 风险 | 处理 |
|---|---|
| 安全软件把「全局低级鼠标钩子」判为可疑 | 托盘菜单一键取消勾选「接管任务栏时间」；托盘图标仍是完整入口，日历数据不受影响 |
| Win10 更新改变任务栏时钟类名 / 结构 | 同上兜底；类名集中在 `kClockClass` 一个常量，扩展只需改这一处 |
| 钩子吞掉了按下却没等到抬起 | `g_clock_pending` 在任何 `WM_LBUTTONUP` 都无条件清除，不会留下「卡住的下」 |
| 自启路径写错 | 用 `GetModuleFileNameW(NULL, ...)` 取当前实际 exe 路径，不写死目录 |
| 进程退出后托盘留幽灵图标 | `Shutdown()` 显式 `NIM_DELETE` 并清理注册表 HWND |
| Flutter 3.22 模板变化 | 补丁脚本逐处断言，CI 会明确报出是哪一处不匹配 |

**边界**：本步只覆盖 Win10。UOS 20 的 DDE Dock 插件 ABI 与
`dde-dock` / `dde-shell` 版本强绑定，实机 DDE 2026.1076.1 属于哪一代尚未确认，
且目标机没有 Qt 开发工具链，不能在未确认前臆测 ABI 就写代码；
UOS 侧先保持正式版不变，下一步先做实机组件探测。

## 五、验收方式（用户侧，不用装任何工具）

1. 下载新的 `cn-calendar-windows-portable`，**完整覆盖**到
   `%LOCALAPPDATA%\CNCalendar\`（自启项路径不变，不用重设）。
2. 双击打开：右下角托盘应出现日历图标。
3. 点任务栏右下角的时间 → 弹出的必须是本软件月历窗口，
   且 9/30 烈士纪念日、休/班角标、四类配色、整月一屏、滚轮整屏推入都正常。
4. 点窗口 X → 窗口隐藏但托盘图标还在；左键托盘图标 → 窗口回来。
5. 再双击一次 exe → 不出现第二个窗口，已有的窗口被叫到前面。
6. 右键托盘 → 分别试「开机自启」「接管任务栏时间」的勾选开关；
   取消「接管任务栏时间」后，点时间应恢复系统自带日历，托盘仍可打开月历。
7. 右键托盘 →「退出」→ 进程结束、托盘图标消失。
8. 观察任务管理器：全程只有**一个** `cn_calendar.exe` 常驻进程。

## 六、本机已验证 / 只认 CI 的部分

**本机已实跑**：

- 用 Flutter 3.22.0 官方 runner 模板（含 `{{projectName}}` 渲染与 CRLF 转换）
  完整模拟 `flutter create` + 打补丁，4 处插入、CMake 追加、幂等防护全部符合预期；
- PowerShell 语法解析 0 错误；
- 三个新文件纯 ASCII，C++ 括号平衡，43 个 Win32 API / 34 个常量名逐一核对；
- Rust 37 测试、`verify_data.py` 2311 项、Dart 词法检查照常通过。

**只认 CI run**：C++ 实际编译、链接、Windows 安装包组装、以及上面第五节
全部实机交互观感。本机无 MSVC / Flutter / Dart 工具链，
不得说「应该能编过」或「应该没残影」。

## 七、CI 与实机进展（2026-11-11）

| 项 | 结果 |
|---|---|
| run | #14 `42950933640`，commit `7b19017`，7/7 job 全绿，总时长 3m3s |
| `build-windows` | 12 步全 success：「接入 P2 托盘与任务栏时间接管」「构建界面」「组装免安装绿色包」均通过 |
| 远程工作流 | `.github/workflows/main.yml` blob sha `93c1c72c…` / 14,527 字节，与本机逐字节一致，隐藏文件夹漏替换问题已消除 |
| 产物 | `cn-calendar-windows-portable` 10,969,799 字节，7 个 artifact 齐全 |
| 二进制证据 | 新 `cn_calendar.exe` 96,256 字节（v0.1.0 为 89,600，+6,656），含 `CNCalendar_SingleInstance_Mutex`、`TrayClockWClass`、`MainWindowHwnd`、`HookTaskbarClock`、`TaskbarCreated`；旧 exe 全无 |
| 实机首批 | 用户确认「软件可以打开」「点 X 后隐藏到托盘」→ 启动链路、`WM_CLOSE` 拦截、托盘图标生效，C++ 编译不再是风险 |
| 实机验收 | **2026-11-11 15:07 用户确认 6 条中的 5 条全通过，第 6 条由本机进程查询替代确认**，见第八节 |

安装落差（**已消除**）：首批试跑从下载解压目录直接运行时，
`%LOCALAPPDATA%\CNCalendar\` 里还是 v0.1.0 的 89,600 字节旧 exe，
而 `HKCU\...\Run\CnCalendar` 指向该目录，重启会起旧版。用户按
`日历操作指南.txt` 追加 20 完整覆盖后，正式安装目录已是
96,256 字节 / 11-11 03:13，与解压目录逐字节一致，自启指向新版。

## 八、实机验收结论（2026-11-11 15:07）

| 验收项 | 结果 | 依据 |
|---|---|---|
| 点任务栏时间弹出本软件月历（核心） | **通过** | 用户实机确认 |
| 取消「接管任务栏时间」后系统日历恢复，托盘仍可打开 | **通过** | 用户实机确认 |
| 托盘左键唤回窗口、X 后图标常驻 | **通过** | 用户实机确认 |
| 再双击 exe 不多开第二个窗口 | **通过** | 用户实机确认 |
| 9/30、休/班角标、配色、整月一屏、滚轮整屏推入无退化 | **通过** | 用户实机确认 |
| 右键退出后图标消失、全程只有一个常驻进程 | **通过（替代口径）** | 用户不便看任务管理器，改由本机进程查询：退出后 `cn_calendar.exe` 0 个、`cn_cal_cli.exe` 0 个，无残留；运行期单实例由「再双击 exe 不多开窗口」确认 |

**判定**：P2 第 1 步 Win10 侧验收完成，钩子风险关闭。
不重启 / 不注销办公机，真实开机自启等用户下次自然开机观察；
桌面透明挂件、UOS DDE Dock 插件（ABI 待实机探测）、托盘月历、
FFI 桥接、双端 24h 资源曲线仍属后续步骤，不计入本步结论。
