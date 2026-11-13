# 中国桌面日历

一个离线优先、无会员、无广告、无备忘录的桌面日历，目标平台 Windows 10 与统信 UOS V20。
显示法定节假日与调休、二十四节气、农历干支，以及**烈士纪念日（9/30）、抗战胜利纪念日（9/3）、
国家宪法日（12/4）、南京大屠杀死难者国家公祭日（12/13）**等我国特色纪念日。

## 设计底线

- 程序本体完全离线：无账号、无登录、无云同步、无遥测
- 不做会员、内购、备忘录、待办、订阅、广告位（代码里不留这些模块）
- 联网只做两件事：**同步年度调休**、**核对日期与节日是否一致**
- 本地已通过测试锁死的计算结果（农历、节气、固定纪念日）**不会被联网数据改写**
- 所有失败都静默降级，绝不弹窗、绝不阻塞启动

## 当前状态

| 阶段 | 内容 | 验证情况 |
|---|---|---|
| **P0 完成** | 四层数据、Rust 计算核心、CLI、测试与校验脚本 | 本机实跑 34 个 Rust 测试 + 2183 项校验 + 联网核对全通过；**UOS 实机核心自检 true/true** |
| **P1 骨架完成** | Flutter 最小月历界面、静默更新器、核对服务、CI、打包模板 | Dart 侧未经本地编译；**CI 7/7 全绿**，Windows / Linux / UOS 界面包均已产出 |
| **P2 进行中** | 任务栏时间入口、开机自启、桌面挂件、托盘常驻、FFI 替换 CLI 桥接 | **第 1 步 Win10 已验收**：run #14（`42950933640`）7/7 全绿，实机 6 条交互全通过，核心的「点任务栏时间弹出本软件月历」已确认。**第 2 步 Win10 桌面挂件代码已落地**（离屏位图 + 分层置底窗口，30 分钟日期哨兵），待 CI 编译与实机验收，见 `docs/P2第二步_Win10桌面挂件.md`；UOS Dock / FFI / 24h 曲线未开始 |
| **UOS 实机体检** | 2026-11-09 只读环境体检 | 已完成：运行环境全部合格，glibc 2.28 为唯一卡点 |
| **UOS 核心实机验证** | 静态 CLI 在 UOS 20 实机跑三条命令 + 重跑体检脚本 | **已通过**：烈士纪念日、11323 天星期连续、农历覆盖全对，无 GLIBC 报错 |
| **UOS 界面实机试跑（旧包）** | ubuntu-22.04 编的 CI Linux bundle 在 UOS 20 启动 | **起不来**：`GLIBC_2.34 not found`；已定位仅 23KB runner 有问题，Flutter 引擎只需 2.18 |
| **UOS 界面包构建** | Debian 10 / glibc 2.28 容器内重编 bundle + `objdump` 符号上限断言 | **CI 已通过**（`build-uos20-bundle` 2m13s），产物 `cn-calendar-uos20-bundle` 可用 |
| **UOS 界面实机复跑** | 新包在 UOS 20 X11 里启动 | **已通过**：窗口稳定驻留、9/30 烈士纪念日可见、休/班角标与翻月正常、81–86 MB / 静止 CPU 1.3% |
| **界面配色与整月一屏** | 四类颜色 + 图例、周日起至周六、动态行数铺满 | 代码已改，**待 CI 与双端复验** |
| **定期校准** | 7 天核对 / 分季节同步 / 手动立即校准 | 代码已改 + 16 个 Dart 测试，**待 CI 复验** |

> 本机环境：`rustc 1.98.0` 可用；`flutter` / `dart` / Linux 构建工具链不可用。
> 因此 Rust 部分以本机 `cargo test` 为准，Flutter 与双端打包部分只认 CI。
>
> CI 实跑（2026-11-09）：首轮 4/5 绿，`build-windows` 因 GitHub 构建机迁移到 VS 2026
> 报错（见「已知风险」第 5 条）；固定 `windows-2022` 并加入构建前 VS 版本校验后，
> 第二轮 **5/5 全绿**：`data-and-core`、`online-verify`、`flutter-analyze`、
> `build-windows`、`build-linux-bundle`。
> 该轮另有 5 条 GitHub 平台自身的 `Node.js 20 is deprecated` 警告与
> `ubuntu-latest` 迁移提示，均不影响构建结果。
> 第三轮新增 `build-uos20-cli`（musl 静态核心），**6/6 全绿**（该 job 31s 通过），
> 产物已下载到 UOS 20 实机运行验证，见下节。
> 第四轮：界面实机试跑发现 runner 要求 GLIBC_2.34（见下节），据此处方新增
> `build-uos20-bundle`（Debian 10 / glibc 2.28 容器内重编整个 bundle，
> 并用 objdump 断言产物 glibc 符号上限），同时把三个 `ubuntu-latest`
> 固定为 `ubuntu-22.04` 防镜像漂移。
> 第四轮 run `42580650018` 为 6 绿 1 红：**容器内 Flutter 编译本身已成功
> （3m23s）**，仅「组装 UOS 包」因容器以 root 写入 `app/build`，
> 宿主 runner 用户 `cp ... cn_cal_cli` 报 `Permission denied`；
> 已在组装前加 `sudo chown -R "$(id -u):$(id -g)" app/build` 取回所有权。
> 第五轮 **7/7 全绿**（commit `Fix permission issue in UOS package assembly step #5`，
> 总时长 2m51s，5 个 artifact）：`data-and-core` 17s、`online-verify` 19s、
> `build-uos20-cli` 30s、`flutter-analyze` 28s、`build-windows` 2m17s、
> `build-linux-bundle` 1m31s、`build-uos20-bundle` **2m13s**。
> `sudo chown` 修复生效；Debian 10 容器内编译、`objdump` glibc 符号上限断言、
> 静态 CLI 组装与 `day 2026-09-30` 自检全部通过，产物 `cn-calendar-uos20-bundle` 可用。
> **但仍是构建侧结论**：CI 没有启动窗口，UOS 20 实机复跑是唯一验收口径。
> 该轮 commit 名只涉及权限修复；低资源改动（`resource_policy.dart` 等）与
> Dart 测试是否已随包上传，以仓库 `app/lib/` 实际文件为准，
> 若尚未上传则需下一轮 CI 复验，不影响本轮产物试跑。
> 第六轮（本轮改动）待 CI run：界面配色与整月一屏、定期校准策略、16 个 Dart 测试，
> 连同上一轮尚未确认的低资源改动一起推上去复验。

## 本机复现验证（Windows + Git Bash）

工作目录含中文「日历」，MinGW `ld` 会找不到 `.o`；且 PATH 上的 `rustc`/`cargo` 是
0 字节占位 shim（os error 193）。两条都要绕开：

```bash
cd "C:/Users/unesc/Downloads/日历/core"
export CARGO_TARGET_DIR="C:/Temp/cncal_target"       # 纯 ASCII 目标目录
export RUSTC="$(rustup which rustc)"                  # 指向真实 toolchain
export RUSTDOC="$(rustup which rustdoc)"
"$(rustup which cargo)" test --offline
```

数据侧与联网核对：

```bash
cd "C:/Users/unesc/Downloads/日历"
python tools/verify_data.py                           # 2183 项自洽校验
node tools/gen_lunar_table.js --check                 # 生成器复现性
node tools/cross_check_lunar.js \
  "C:/Temp/cncal_target/debug/cn_cal_cli.exe"         # 双实现逐日交叉核对
python tools/verify_online.py \
  --cli "C:/Temp/cncal_target/debug/cn_cal_cli.exe" \
  --cache "C:/Temp/cncal-cache"
```

本次实跑结果（2026-11-09）：

```
状态: consistent
  [ok] http-date-weekday: 3 个 HTTP 源，Date 头 2026-11-09T01:34:47+00:00，权威星期 1，本机星期 1
  [ok] weekday-continuity: 11323 天往返与星期循环检查
  [ok] holiday-2025/2026/2027: 内置 33/39/34 条，差异 0 处
  [ok] festival-sampling: 核对 106 条调休日 + 12 个国家级纪念日，问题 0 处
```

双实现交叉核对（lunar-javascript 逐日独立计算 vs Rust 核心输出）：

```
交叉核对范围 2020-01-25 ~ 2050-12-31，共 11299 天，372 次 CLI 调用
lunar.month/day/leap/text、jieqi、ganzhi、shengxiao 差异均为 0
OK: 双实现逐日一致
```

发现差异时退出码 2 并写出 `verify-report.json`；断网时状态为 `offline`，退出码 0。

## 目录

```
data/                      四层日历数据（L1 固定纪念日 / L2 规则 / L3 农历表 / L4 年度调休）
core/                      Rust 计算核心，零外部依赖
  src/bin/cn_cal_cli.rs     界面桥接与核对命令
  tests/core_tests.rs       24 个集成测试（含 2020–2050 全范围连续性、节日正日语义）
app/                       Flutter 3.22 最小界面（P1 骨架）
tools/                     数据生成、自洽校验、联网核对
docs/                      方案定稿、数据规范、核对规范
packaging/uos/             UOS 20 deb 打包模板与实机验证清单
reports/                   核对报告与 UOS 实机留档（含机器路径的文件已 .gitignore）
.github/workflows/main.yml CI：数据/核心/联网核对/静态检查/双端构建/UOS 静态核心（仓库里的文件名）
```

## 运行界面（开发期）

```bash
cd core && cargo build --offline --bin cn_cal_cli
cd ../app
flutter create --platforms=windows,linux --project-name cn_calendar --org cn.calendar .
flutter pub get
# 让界面找到 CLI：把 cn_cal_cli 放到主程序同目录，或设置 CN_CAL_CLI
flutter run -d windows
```

环境变量：

| 变量 | 作用 |
|---|---|
| `CN_CAL_CLI` | `cn_cal_cli` 可执行文件路径；默认取主程序同目录 / PATH |
| `CN_CAL_CACHE_DIR` | 调休缓存与核对报告目录；默认 `~/.cn_calendar/cache` |
| `CN_CAL_HOLIDAY_DIR` | 核心读取的调休缓存目录；界面侧与 `CN_CAL_CACHE_DIR` 一致 |

## 数据来源

- **L4 调休**：[holiday-cn](https://github.com/NateScarlet/holiday-cn)（GitHub Actions 每日同步国务院办公厅公告），
  内置 2025 / 2026 / 2027 三年真实快照，保留公告原文链接
- **L3 农历节气**：由 [lunar-javascript 1.7.0](https://www.npmjs.com/package/lunar-javascript) 预生成
  2020–2050 静态表，生成脚本与上游文件均入库，可复现校验
- **L1 固定纪念日**：全国人大常委会决定与国务院规定，见 `data/memorial-days.json` 的 `law` 字段

## UOS 20 实机体检（2026-11-09，只读）

留档：`reports/uos-check-report.json`、`reports/UOS体检结果.txt`（含目标机器本地用户路径，
已加入 `.gitignore`，不进公开仓库；`reports/verify-report.json` 仍入库）。

| 项目 | 实测 | 判定 |
|---|---|---|
| 系统 / 内核 | UOS Desktop 20 Professional（eagle）/ 4.19.0-amd64-desktop | 符合目标 |
| glibc | 2.28.36-deepin1 | 与 Debian 10 同系；CI 动态产物须用 ≤ 2.28 环境 |
| CPU 架构 | x86_64 | 起步架构，无需改 Qt 重写 UI |
| 会话 / 桌面 | X11（DISPLAY=:0）/ DDE 2026.1076.1 | Flutter Linux 首选 X11 |
| 显卡 | Glenfly Arise1020，OpenGL 4.5、Mesa 25.00.58、direct rendering: Yes | 硬件加速正常，非软件渲染 |
| 关键库 | libgtk-3.so.0 / libGL.so.1 / libX11.so.6 全部存在 | 界面硬性依赖齐全 |
| 开发工具 | 无 flutter / dart / rustc / clang / cmake / ninja；有 git 2.20.1、python3 3.7.3、dpkg-deb、pkg-config | 不必在 UOS 装工具链 |
| 核心自检 | 初检未跑（当时无 `cn_cal_cli`） | 14:57 复验通过，见下 |

**结论**：库、会话、显卡、架构全部合格，运行环境没有障碍；唯一卡点是
glibc 2.28 与 CI 构建环境不匹配，属构建侧问题，不是 UOS 缺陷。
体检报告里「现在还跑不了界面」应理解为「还没有可运行的程序本体」，
不是「这台机器跑不了」。脚本用系统自带 Python 3.7.3 跑通，兼容目标达成。

### 核心实机验证（2026-11-09 14:57）

用 `build-uos20-cli` 产出的 musl 静态 `cn_cal_cli`（713,472 字节）在 UOS 实机运行：

| 检查 | 结果 |
|---|---|
| 二进制形态 | `ldd` = statically linked，无 PT_INTERP / NEEDED / `GLIBC_` 符号（`file` 显示为 dynamically linked 是 PIE 静态可执行文件的常见误判） |
| `day 2026-09-30` | 烈士纪念日（国家级纪念日 / L1），`weekday=3` 与系统 `date` 一致 |
| `verify weekday` | 2020-01-01～2050-12-31 共 11323 天，`consistent:true`、`mismatches:[]` |
| `range` | 2020-01-25 ～ 2051-02-11，覆盖 2020–2050 共 31 年 |
| `CN_CAL_CLI=... python3 tools/uos_check.py` | `core_day_ok=true`、`core_weekday_ok=true`、`cli` 非空 |
| GLIBC 报错 | 无；三条命令退出码均为 0 |

**结论：glibc 2.28 的障碍对计算核心已被静态链接绕过。** 留档见
`reports/UOS核心验证结果.txt` 与 `reports/uos-check-report.json`
（初检留 `reports/uos-check-initial.json`）。

### 界面实机试跑（2026-11-09 15:15）

把第三轮 CI 的 `cn-calendar-linux-bundle` 传到 UOS 20，用静态 CLI 替换
bundle 内动态 CLI 后，在 X11 里执行 `DISPLAY=:0 ./cn_calendar`：

```
./cn_calendar: /lib/x86_64-linux-gnu/libc.so.6: version `GLIBC_2.34' not found
```

退出码 1，不到 1 秒退出，无窗口、无残留进程，无 GTK / libGL / libX11 缺失提示。
留档 `reports/UOS界面试跑结果.txt`。

**根因定位（本次最关键的发现）**：

| 组件 | 最高 glibc 符号要求 | UOS 20 (2.28) |
|---|---|---|
| `libflutter_linux_gtk.so`（Flutter 引擎） | GLIBC_2.18 | ✓ 能 |
| `libapp.so`（Dart AOT 应用代码） | 无额外要求 | ✓ 能 |
| `cn_calendar`（23,904 字节 C++ runner） | **GLIBC_2.34** | ✗ 不能 |
| `core/target/release/cn_cal_cli`（动态 CLI） | 2.30 / 2.32 / 2.33 / 2.34 | ✗ 不能（已用静态版替代） |

即：UOS 的图形栈、GTK、显卡硬件加速都撑得住 Flutter，失败发生在**程序加载
阶段，与 X11 / 显卡 / 窗口管理器无关**。障碍被收敛到「一个 23KB 启动器在
Ubuntu 22.04 上编译」这一件事，处置方式随之明确：在 glibc ≤ 2.28 环境重编
bundle，不需要在 UOS 上安装任何开发工具。

### 界面实机复跑（2026-11-09 16:37～16:43）—— 通过

第五轮 CI 的 `cn-calendar-uos20-bundle` 经 AirPortal 传到 UOS 20，
扁平包内 `cn_calendar` 24,400 字节、`cn_cal_cli` 静态 713,472 字节。
`DISPLAY=:0 ./cn_calendar`：

| 检查 | 结果 |
|---|---|
| glibc 符号 | 新 runner 最高只需 GLIBC_2.2.5（旧包 2.34），引擎库 2.18，`ldd` 无 not found |
| 窗口 | 正常弹出，X11 标题 `cn_calendar`，1280×720；`timeout 20` 跑满 20 秒（码 124），无残留进程 |
| 报错 | 无 GLIBC_/GLIBCXX_/GTK/EGL/GL 错误；仅 dbind 辅助功能总线与显卡驱动两条无害警告 |
| 静态 CLI 自检 | `day 2026-09-30` → 烈士纪念日，退出码 0 |
| 界面数据 | 11 月农历、立冬、全国消防日、休/班角标；点两下翻到 9 月，9/3 抗战胜利纪念日、教师节、九一八、中秋等齐全 |
| **9 月 30 日** | 拉高窗口后可见**红色「烈士纪念日」**，与 CLI 一致；底部显示「数据核对一致」 |
| 资源 | RSS 82 → 81 → 86 MB（71 秒 +5.7%），静止 CPU **1.3%** |

**结论：UOS 20 图形栈、glibc 2.28 兼容、Flutter EGL/GL 初始化、GUI 交互
全部实机通过**，这是本项目最关键的验收节点。留档
`reports/UOS界面复跑结果.txt` 与 5 张截图（含目标机本地路径，已 `.gitignore`）。
复跑同时暴露一处界面缺陷：默认 1280×720 只显示前三周、月底需滚动，
本轮已改为按当月行数动态铺满一屏。

## 低资源运行优化（2026-11-09 新增需求）

用户补充：两台办公机配置不高（Win10 i3-8100 / 16GB；UOS 海光 C86-3G 3350 / 16GB），
要求运行占用资源少。**结论：改动前不完全满足，已按需求修改软件，未更换技术栈。**

16 GB 内存并不紧张，浪费在启动峰值与后台空转：改动前每次启动都要拉 5–7 个
CLI 进程、最多发 6 个网络请求，并每次重跑 11323 天星期连续性核对。
量化口径与实测数据见 `docs/资源占用规范.md`。

| 文件 | 改动 |
|---|---|
| `app/lib/resource_policy.dart`（新增） | 定期校准：核对 7 天、L4 同步按发布季分频（11–1 月 1 天 / 其余 30 天）、offline 6 小时、跨年与时钟回拨强制重跑、`MonthCache` 12 个月上限 |
| `app/lib/verify_service.dart` | 命中缓存零网络零 CLI 进程；`run(force: true)` 支持界面「立即校准」；`dataChanged` 上报 L4 更新 |
| `app/lib/update_service.dart` | `syncQuietly()` 返回是否写入新 L4；失败也写标记 |
| `app/lib/calendar_bridge.dart` | 月份结果内存复用 |
| `app/lib/main.dart` | 更新后清空缓存重取当月 + `_loadSeq` 并发保护；四类配色、图例、整月一屏、立即校准按钮 |
| `app/lib/day_info.dart` | `DayKind` 与 `dayKind` 分类（补班 > 法定假 > 周末 > 工作日） |
| `app/test/widget_test.dart` | 16 个测试，覆盖配色分类、分季节间隔、跨年/回拨、节流、缓存 |

日常启动从 5–7 个 CLI 进程 + 最多 6 个请求降到 **1 个进程 + 0 个请求**；
联网核对由「每次启动」改为「默认 7 天一轮」，L4 同步改为「11–1 月每天 / 其余 30 天」。
精确性没有被削弱：本地日期/星期/农历每次启动照算，L1/L2/L3 不被联网改写，
差异一律出报告，跨年或时钟回拨强制重跑，用户随时可点「立即校准」走完整核对，
L4 一旦更新界面立即失效缓存重取。
UOS 实机初测 81–86 MB / 静止 CPU 1.3%，见 `docs/资源占用规范.md`。

**尚未验收**：Win10 侧 GUI 资源采样未完成（60 秒窗口内进程消失，已确认无残留），
24 小时内存漂移曲线未量；本机无 Flutter/Dart，界面与策略改动的静态检查、
28 个 Dart 测试只认 CI run。

## 用户追加需求（2026-11-09 16:59）

| # | 要求 | 裁决 / 状态 |
|---|---|---|
| 1 | 点击任务栏日历/时间弹出的界面就是本软件界面；不必真正替换系统自带日历，效果满足即可 | 采纳「接管入口、不碰系统组件」；**Win10 已实机验收通过**（P2 第 1 步，run #14 全绿）：点任务栏时间弹出本软件月历、取消接管后恢复系统日历、托盘兜底均确认，见 `docs/P2第一步_Win10托盘与时间接管.md`；UOS Dock 插件待 ABI 探测 |
| 2 | 常驻后台 + 桌面插件；更新不要太频繁，固定/提前定好的数据只需定期校准，但必须精准 | **策略已落地**：7 天核对、分季节同步、手动立即校准、本地计算不降频；**Win10 桌面挂件代码已落地（P2 第 2 步，待 CI + 实机验收）**，30 分钟日期哨兵只在跨天时重绘一次，见 `docs/P2第二步_Win10桌面挂件.md` |
| 3 | 开机自启是必须的，桌面插件也要开机自启 | **打包级自启已落地**：Win10 `HKCU\...\Run` 开关、UOS `/etc/xdg/autostart` 与免 root 用户级 autostart，均配显式关闭；桌面插件本体与入口接管仍待 P2 |
| 4 | 颜色区分周末、假期和工作日；一周周日起至周六 | **已落地**：四类配色 + 图例；列序本就是周日起至周六止，已加注释锁死 |

顺带修掉复跑实测暴露的「默认窗口只显示前三周」缺陷：现按当月实际行数动态铺满一屏。
完整对照、两端实现路径与验收方式见 `docs/P2桌面形态方案.md`。

## 安装包与开机自启（2026-11-09 17:57）

新版界面在 UOS 20 实机确认后，本轮把「能跑的程序」做成「能装的成品」。
CI 仍是 7 个 job，新增两道**只打包不编译**的工序与两个 artifact：

| artifact | 内容 | 开机自启 |
|---|---|---|
| `cn-calendar-windows-portable` | Windows Release 目录 + `cn_cal_cli.exe` + 自启开关 + README 压成 zip | `enable-autostart.bat` / `disable-autostart.bat`，写 `HKCU\Software\Microsoft\Windows\CurrentVersion\Run`，仅当前用户、无需管理员 |
| `cn-calendar-uos20-deb` | `/opt/cn-calendar/`（Debian 10 重编 runner + musl 静态 CLI + `lib/` + `data/`）、`/usr/bin/cn-calendar`、应用菜单项与 SVG 图标 | `/etc/xdg/autostart/cn-calendar.desktop`，XDG 标准登录自启 |

deb 由 `packaging/uos/build_deb.sh` 用 `dpkg-deb` 组装；包内二进制仍来自
glibc ≤ 2.28 的 Debian 10 容器，`build-uos20-bundle` 已用 `objdump -T`
断言 runner 最高 glibc 符号不超过 2.28。`build_deb.sh` 自身也会断言
bundle 内必须有 `cn_cal_cli`，缺了直接失败。CI 打包后用 `dpkg-deb -I`
与 `dpkg-deb -c` 校验主程序、静态 CLI、启动器、自启项四件套齐全。

打包目录：`packaging/uos/` 含 `build_deb.sh`、`DEBIAN/control`、
`cn-calendar.desktop`、`cn-calendar-autostart.desktop`、
`cn-calendar-launcher.sh`、`cn-calendar.svg`、`install-user.sh`、`README.md`；
`packaging/windows/` 含 `enable-autostart.bat`、`disable-autostart.bat`、`README.txt`。
`install-user.sh` 是不方便 `sudo` 时的免 root 路径：装到
`~/.local/share/cn-calendar`，自启写 `~/.config/autostart/`，不改系统目录。
两端都配显式关闭方式，见 `packaging/uos/README.md`。
启动脚本显式设置 `CN_CAL_CLI`；Windows 绿色包由
`CalendarBridge.defaultCliPath()` 取与主程序同目录的 `cn_cal_cli.exe`。

**后续状态更新**：Win10 已正式安装到 `%LOCALAPPDATA%\CNCalendar\` 并写入
HKCU Run 自启项；两端自启只验到「自启项落地 + 能弹窗」，不重启 / 注销办公机，
真正开机自启由用户下次自然开机确认。详见 `docs/正式版验收结论.md`。
给 UOS 的实机指令见本机 `给UOS的第5步_安装验证.txt`（Downloads 目录，不进仓库）。

## P2 第 1 步：Win10 托盘常驻 + 接管任务栏时间（2026-11-10 16:40）

用户「开始做P2」后按「一次只改一件事」启动的第一步。**只改 Win10 侧**，
Linux runner、Dart 数据链路、四层数据、切月动画全部零改动，
因此 UOS 正式包产物不变、**UOS 不需要重装也不需要重验**。

| 项 | 内容 |
|---|---|
| 入口接管 | `WH_MOUSE_LL` 只读钩子识别 `TrayClockWClass`，吞掉这次点击并弹出同一个 Flutter 月历窗口；不碰系统组件 |
| 常驻形态 | X 按钮隐藏到托盘；托盘左键显示 / 隐藏，右键菜单含打开月历、接管开关、开机自启开关、退出 |
| 单实例 | 命名 Mutex + 注册表缓存 HWND，第二个进程只唤起已有窗口后退出，全程一个常驻进程 |
| 接入方式 | `packaging/p2/windows/apply_p2_patch.ps1` 在 CI 里对 `flutter create` 生成的 runner 做 4 处精确插入 + 1 个新 `.cpp`；逐处断言，模板变化会明确报错 |
| 兜底 | 安全软件拦钩子 / Win10 更新改了任务栏结构 → 菜单取消勾选「接管任务栏时间」，托盘入口仍完整可用 |
| 尚未做 | 桌面透明挂件、UOS DDE Dock 插件、托盘月历、FFI 替换 CLI 桥接、双端 24h 曲线 |

本机已用 Flutter 3.22.0 官方模板（含 CRLF 转换）完整模拟 `flutter create` +
打补丁，4 处插入、CMake 追加、幂等防护、PowerShell 语法、纯 ASCII 与
43 个 Win32 API / 34 个常量名逐一核对通过；**C++ 编译、链接、打包与全部
实机交互观感只认 CI run + Win10 实机**，本机无 MSVC / Flutter / Dart。
完整设计与验收步骤见 `docs/P2第一步_Win10托盘与时间接管.md`。

### CI 与实机进展（2026-11-11）

run #14 `42950933640`（commit `7b19017`）**7/7 全绿**，总时长 3m3s。
`build-windows` 12 步全 success，其中「接入 P2 托盘与任务栏时间接管」
「构建界面」「组装免安装绿色包」均通过，产出
`cn-calendar-windows-portable`（10,969,799 字节）；7 个 artifact 齐全。
远程 `.github/workflows/main.yml` 的 Git blob sha `93c1c72c…` /
14,527 字节与本机逐字节一致，隐藏文件夹漏替换问题已消除。

二进制证据：新 `cn_calendar.exe` 96,256 字节，比 v0.1.0 的 89,600 字节
多 6,656 字节，可检出 `CNCalendar_SingleInstance_Mutex`、`TrayClockWClass`、
`MainWindowHwnd`、`HookTaskbarClock`、`TaskbarCreated` 等 P2 字符串，
旧 exe 全无 —— 补丁确实编进了产物，不只是脚本跑过。
Win10 实机首批反馈：**软件可打开、点 X 隐藏到托盘**，即启动链路、
`WM_CLOSE` 拦截、托盘图标均生效。

**实机验收（2026-11-11 15:07）**：用户侧 6 条交互项全部确认 ——
**点任务栏时间弹出本软件月历（核心效果）**、取消「接管任务栏时间」后
系统自带日历恢复、托盘左键唤回窗口、再双击 exe 不多开第二个窗口、
X 之后托盘图标仍在、9/30 与休/班角标 / 配色 / 整月一屏 / 滚轮推入无退化。
第 6 条「右键退出 + 只有一个常驻进程」用户不便看任务管理器，
改由本机进程查询佐证：退出后 `cn_calendar.exe` 0 个、`cn_cal_cli.exe` 0 个，
无残留；运行期单实例由「再双击 exe 不多开窗口」确认。**钩子风险关闭**。

安装落差已消除：用户按操作指南追加 20 把新版完整覆盖到
`%LOCALAPPDATA%\CNCalendar\`（96,256 字节 / 11-11 03:13），
解压目录与正式安装目录的 exe 现已逐字节一致，开机自启指向新版。
重启后的真实自启表现仍等用户下次自然开机确认，不重启办公机去验。

本轮 `build-windows` 新增补丁步骤，三份 `main.yml`（项目、上传包、
`粘贴到GitHub的内容.txt`）已同步，当前 md5
`aace78c98eaf6bde31da27db54177cc6`；前文出现的
`ce6975d1f87aadce2643b9e7a6b77158` 是 v0.1.0 定稿时的历史值。

## P2 第 2 步：Win10 桌面挂件（2026-11-11 15:17）

用户「先做WIN10桌面挂件」。仍按「一次只改一件事」，只做 Win10：
透明、置底、只读、随自启的整月挂件，返回桌面即可看见日历。
**UOS 产物一个字节不变**，不用重装 / 重验。

| 项 | 内容 |
|---|---|
| 渲染 | Dart `ui.PictureRecorder` 离屏画整月（复用 `CalendarPalette` 与 `DayInfo`），输出 448×424 的 32bpp BGRA 位图 |
| 通道 | 位图写入 `cachePath()/widget_image.bin`，写完才用 `dart:ffi` 的 `PostMessageW(WM_APP+5)` 通知；**不碰 Flutter embedder C++ API** |
| 窗口 | `WS_EX_LAYERED \| NOACTIVATE \| TRANSPARENT \| TOOLWINDOW` + `HWND_BOTTOM` + `LWA_ALPHA=216`；原生层只 `BitBlt`，不解析 JSON、不画文字 |
| 刷新 | 启动 / 回到当月 / L4 更新 / 主题切换 / 跨天；翻到别的月份不重画。日期哨兵每 30 分钟只比一次「年-月-日」，日期变化才重绘一次 |
| 开关 | 托盘右键新增「桌面挂件」勾选，写 `HKCU\Software\CNCalendar\WidgetEnabled`，默认开 |
| 资源 | 不新增进程、不新增线程、不新增原生定时器、不联网；静止时无 `WM_PAINT`，内存只多一张约 763 KB DIB |

**刻意不改 `main.yml` 与 `apply_p2_patch.ps1`**：挂件代码直接扩写进已有的
`cn_calendar_p2.cpp/.h`，补丁脚本只是把这两个文件复制进 runner，
内容变化不需要改脚本。因此网页「全选覆盖上传」再次漏掉隐藏 `.github`
也不会有任何后果 —— 这是上一轮踩坑后特意选的形态。

**本机已验证**：Flutter 3.22 官方模板完整模拟 `flutter create` + 打补丁
4/4 通过；三个 P2 源文件纯 ASCII、C++ 括号平衡与 92 个 Win32/GDI 调用名
逐一核对；Dart 括号平衡、33 个测试计数、新增源码契约 17/17 + 16/16；
Rust 37 测试、2311 项数据校验照常通过。
**只认 CI run 与实机**：C++ 编译 / 链接（gdi32 / user32 是否由默认库带入）、
`dart:ffi` 加载 `user32.dll`、离屏渲染与中文字体、`rawRgba` 通道顺序、
`HWND_BOTTOM` 的实际可见性、托盘开关行为。本机无 MSVC / Flutter / Dart，
不得说「应该能编过」或「应该看得见」。

完整设计、契约与 8 条验收见 `docs/P2第二步_Win10桌面挂件.md`。

## 双端试用反馈与修正（2026-11-10）

### Win10 首次运行报「找不到日历核心」

实机截图报错：`ProcessException: 系统找不到指定的文件。Command: cn_cal_cli.exe month 2026 11`。
**根因是下载错了产物**：用户下的是 `cn-calendar-windows-x64`（开发用原始目录），
其中 `cn_calendar.exe` 在 `app/build/windows/x64/runner/Release/`、
`cn_cal_cli.exe` 在 `core/target/release/`，两者不同目录，
`CalendarBridge.defaultCliPath()` 因此退回裸名交给 PATH，而 `Process.run`
传 `environment` 时又会整体替换父进程环境，PATH 一并丢失。

三处修复，任一环节单独失效都不再白屏：

| 文件 | 改动 |
|---|---|
| `app/lib/calendar_bridge.dart` | `defaultCliPath()` 多候选探测：同目录 → `data/` → 向上 7 层逐级查 `core/target/release/`；`childEnvironment()` 把 `Platform.environment` 与 `CN_CAL_HOLIDAY_DIR` 合并；`ProcessException` 转成中文排障提示并带完整路径 |
| `app/lib/main.dart` | 错误页去掉 `Bad state:` 前缀，显示核心实际路径与「请把 CLI 放旁边 / 被安全软件隔离请恢复」 |
| `日历操作指南.txt` 追加 10 | 明确只下载 `cn-calendar-windows-portable`，并给 10 秒自检（解压后两个 exe 是否在同一文件夹） |

**CI 仍会产出 `cn-calendar-windows-x64`，它是开发产物，用户不要下载。**

### 用户 8 条界面与数据反馈

| # | 反馈 | 改动 |
|---|---|---|
| 1 | 周末 / 节假日淡蓝数字不明显，改用橙红 | 周末与法定假期的**日期数字**统一橙红（黑色模式 `#FF8A65` / 白色模式 `#D84315`）；四类区分仍由背景色承担（周末蓝、假期绿、补班橙） |
| 2 | 缺少下元节等传统节日 | 新增破五、龙抬头、上巳节、寒衣节、下元节、冬至节；农历节日 9 → 14 条。未收录小年（南北腊月廿三/廿四不一致）与寒食节（清明前一日，规则引擎暂不支持相对节气），取舍写在 `data/rule-days.json` 的 `meta.note` |
| 3 | 节假日与纪念日要加粗标注 | 格子里有节名的文字 10 → 11 号、字重 `w700` 并用橙红/红色；日期数字有节名时也加粗 |
| 4 | 放假不等于整段都是节（国庆 10/1—7、中秋同理） | 新增 `data/festival-anchors.json`；核心只在**节日正日**保留节名，其余假期日只留 `holiday_name`（配色）与「休」角标；连休合并名如 2025「国庆节、中秋节」按 `compound` 分别命中 10/1、10/6 |
| 5 | 「休」「班」要加大加粗 | 角标 10 → 13 号、字重 `w900`、加圆角底色；补班与休假用不同底色 |
| 6 | 只有黑色，要黑白两种模式 | 新增白色模式，右上角按钮切换，写入 `~/.cn_calendar/cache/theme.txt` 持久化；两套 `CalendarPalette` 与 `ThemeData` |
| 7 | 鼠标滚轮切月 | `Listener` + `PointerScrollEvent`，250ms 节流防一次手势连翻多页，上滚上月 / 下滚下月 |
| 8 | 点左上角日期快速跳年月 | 标题可点，弹窗里左右切年份、12 个月网格一点到位，范围 2020–2050（农历覆盖范围），带「回到本月」 |

### 本机复验（Rust / 数据侧）

- `cargo test --offline`：**37 个测试全绿**（12 单元 + 24 集成 + 1 doctest），
  新增 3 个集成测试锁死「只有正日有节名」「连休两个正日」「新增传统节日日期」。
- `tools/verify_data.py`：**2311 项校验全部通过**，新增锚点覆盖校验
  （所有内置 L4 假期名必须登记正日，否则漏标节日）与农历节日日期去重校验。
- CLI 逐日核对：`2026-10-01` 有国庆节、`10-02/10-07` 无节名；
  `2026-09-25` 有中秋节、`09-26` 无；`2025-10-01` 国庆节、`2025-10-06` 中秋节；
  `2026-11-23` 下元节（农历十月十五）、`2026-11-09` 寒衣节、`2026-12-22` 冬至节。
- `tools/verify_online.py` 新增 `festival-anchor` 核对项：正日必须真的带节名标签，
  旧版核心缺 `festival_day` 字段时自动跳过、不误报。
- **Dart / 界面改动本机无法编译**（无 Flutter/Dart），配色、双主题、滚轮、
  年月弹窗与当轮新增的 3 个 Dart 测试只认 CI run，不得说「应该能编过」。
  第三轮又补了 5 个测试，见下一节。

### 第三轮修正：Win10 编码坑与同格双标签（2026-11-10 傍晚）

用户反馈「两个 exe 已在同一文件夹，Win10 打开 `cn_calendar.exe` 仍旧失效」。
本机复现后确认根因与**文件路径无关**：Rust 核心输出 UTF-8，而中文 Windows 下
Dart `Process.run` 默认按 `systemEncoding`（GBK）解码 stdout，「丙午」「寒衣节」
等多字节中文变成非法字符，`jsonDecode` 抛 `FormatException`，界面白屏。
本机复现输出：

```text
原始字节数: 367
按 UTF-8 解码: {"date":"2026-11-09",...,"labels":[{"name":"全国消防日"...
按 GBK 解码直接抛错: 'gbk' codec can't decode byte 0xa5 in position 94
UTF-8 解析 JSON: OK -> 丙午 马
GBK 解析 JSON 失败: UnicodeDecodeError
```

| 改动 | 文件 |
|---|---|
| 两处 `Process.run` 显式 `stdoutEncoding: utf8, stderrEncoding: utf8` | `app/lib/calendar_bridge.dart`、`app/lib/verify_service.dart` |
| 整月 JSON 解析抽成 `CalendarBridge.parseMonth(String)`，便于回归测试 | `app/lib/calendar_bridge.dart` |
| `primaryText` 最多露两个标签，按 节日/国家级纪念日 > 法定假/调休 > 纪念日 > 主题日 排序 | `app/lib/day_info.dart` |
| 界面原本已有 `maxLines: 2`，两行标签无需再改布局 | `app/lib/main.dart` |
| 新增 5 个 Dart 测试：两处显式 UTF-8、中文不丢字、双标签优先级、三标签截断、退回节气/农历 | `app/test/widget_test.dart` |

同时修掉 UOS 第 6 步唯一遗留：`2026-11-09` 格子里现在同时显示「寒衣节」与
「全国消防日」，不必再点进详情弹窗。用户回传的
`UOS带回Windows_全部报告与截图_20261110.zip`（34 个文件）结论为
「8 条验收 7 条完全通过，可以升级成正式 deb 安装包」，资源仍稳定
（静止 70 秒 RSS 89,852 KB / CPU 1.6%，60 秒只涨 8 KB）。

**本机复验（本轮）**：

- `cargo test --offline`：**37 个测试全绿**（12 单元 + 24 集成 + 1 doctest）
- `tools/verify_data.py`：**2311 项校验全部通过**
- `python -m py_compile` 两个校验脚本通过；5 个 Dart 文件词法级括号平衡检查通过
- `widget_test.dart` 测试数 **19 → 24**
- 项目与 `日历_上传包` **54 / 54 文件逐字节一致**；三份 `main.yml` 内容未改，
  md5 仍为 `ce6975d1f87aadce2643b9e7a6b77158`（305 行）
- **Dart 编译与两端打包仍只认下一轮 CI run**（本机无 Flutter/Dart），不得说「应该能编过」

### 第四轮：滚轮翻月动画（2026-11-10 11:35 追加，**已于第五轮整体回退**）

> 注意：本节记录的是一次**失败的尝试**。用户正式安装后实机发现文字残影，
> 动画代码已全部删除。现行实现以第五轮的「瞬间切换」为准，
> 不要把本节描述当成还在生效的代码。

**CI run #10 全绿**（7 jobs / 3m10s / 7 artifacts）；**Win10 绿色包试跑成功**：
中文不乱码、整月一屏、`2026-11-09` 格子里「寒衣节 / 全国消防日」两行完整可见。
UOS 回传 `UOS带回Windows_全部资料_含第7步_20261110.zip`（37 个文件）：
第 7 步寒衣节回归**完全通过**——9 日格子第一行橙红加粗「寒衣节」、第二行
「全国消防日」，两行不截断、不用点详情；数据层两条 labels 都在；配色、休/班角标、
整月一屏、图例与「数据核对一致」保持原样；静止 91,992 KB / CPU 1.5%，
60 秒仍只涨 8 KB。报告结论原文：「可以升级成正式 deb 安装包了」。

用户新增建议：滚轮翻月有效，但希望有符合操作方向的**滑动动画**。

| 改动 | 文件 |
|---|---|
| 新增 `CalendarMotion`：一次性 220ms 过渡、位移 12%、方向随滚轮 | `app/lib/main.dart` |
| `AnimatedSwitcher` + `SlideTransition` + `FadeTransition`；`StackFit.expand` 给动态 `Column+Expanded` 格子紧约束 | `app/lib/main.dart` |
| `_shownMonthKey` 绑定「真正到位的数据」，避免新月份数据没到就先播动画、格子却还是旧月份 | `app/lib/main.dart` |
| 换月不再闪进度圈（只有首屏转圈）；连滚时 `_loadSeq` 丢弃中间请求，只播一次 | `app/lib/main.dart` |
| 点标题跳年月按目标先后决定方向，与滚轮同向 | `app/lib/main.dart` |
| 新增 3 个 Dart 测试（时长/幅度、下滚方向、上滚反向），总数 **24 → 27** | `app/test/widget_test.dart` |
| 资源规范补第 8 条：一次性动画 ≠ 常驻动画；补三轮 UOS 复测数据 | `docs/资源占用规范.md` |

方向口径：**下滚 → 去下个月 → 新页自下方滑入、旧页被推向上方**；
上滚 → 回上个月 → 方向完全相反。`transitionBuilder` 用方法 tear-off 保持
引用稳定，`dy` 在 entry 创建时固化进 Tween，动画期间不被后续滚轮改写
（已对 Flutter 3.22 源码确认：builder 收到的是原始 child，key 保持不变）。
`AnimatedSwitcher` 的 controller 在 220ms 后停在 completed、Ticker 静默，
静止时不再请求帧；切主题、命中缓存、界面空闲都不播动画。

**本机复验**：Rust 37 测试、`verify_data.py` 2311 项、Dart 词法括号检查；
项目 / 上传包逐字节一致；三份 `main.yml` 内容未改
（md5 `ce6975d1f87aadce2643b9e7a6b77158`）。
**动画的实际观感与 Dart 编译只认下一轮 CI run + 双端实机**，
本机无 Flutter/Dart，不得说「应该能编过 / 应该好看」。

### 第五轮：一度回退切月动画（2026-11-10 11:59，**已按用户要求改为第六轮的优化动画**）

> 本节记录了一次方向性偏差：用户明确要求「调整和优化滚动动画」，
> 而不是回到无动画版。现行实现以第六轮的「整屏推入」为准。

用户正式安装带动画的版本后反馈：「滚动效果不理想，滚动时会有文字的
残影残留，反而影响使用。」

**根因（确认）**：`transitionBuilder` 用 `FadeTransition` 做交叉淡入淡出，
220ms 内新旧两页同时可见；`layoutBuilder` 用 `Stack` 把两页叠在一起，
而月历格子底色本身是半透明的（`CalendarPalette.weekendBg` 等为 `0x14...`），
底层文字透过上层显示 → 两层中文重叠成重影。位移只有 12%，两页几乎
完全重合，进一步放大残影。**这不是性能问题或显卡问题**，调曲线、缩时长
都无法保证消除。

**决策**：不继续调参，整体回退到 run #10 已实机确认好用的瞬间切换。
理由：残影属于可用性倒退；改良版（整屏推入）需要再赌一轮双端观感，
而用户已完成正式安装，返工成本高；低资源口径本就倾向零动画。

| 改动 | 文件 |
|---|---|
| 删除 `CalendarMotion`、`_slideDirection`、`_shownMonthKey`、`_monthTransition` | `app/lib/main.dart` |
| `_buildBody` 恢复 `Expanded(child: _buildGrid())`，格子只渲染一页 | `app/lib/main.dart` |
| `_loadMonth` / `_shiftMonth` / `_showMonthPicker` 恢复 run #10 行为 | `app/lib/main.dart` |
| 删掉 3 个动画测试，新增 1 个源码级防残影断言（禁止再引入双页过渡 / 淡入 / 滑动） | `app/test/widget_test.dart` |
| 资源规范第 8 条改写为「刻意不做切月动画」 | `docs/资源占用规范.md` |
| 追加 14 说明覆盖安装步骤；第 8 步 UOS 指令文件标注作废 | `日历操作指南.txt`、`给UOS的第8步_翻月动画抽验.txt` |

**保留不变**：8 条界面改动、Win10 UTF-8 编码修复、同格双标签、双主题、
滚轮 250ms 节流翻月、点标题跳年月、定期校准、开机自启、四层数据与
全部精确性校验。**本次一个字节的日历数据都没动。**
Dart 测试 27 → **25**（24 个功能测试 + 1 个防残影回归）。

以后若确要滑动，唯一稳妥路线：整屏推入、两页**不重叠**、**不淡入**、
每页不透明底 + `ClipRect`，且必须先过 Win10 / UOS 双端实机验收；
不要再回到「小位移 + 交叉淡入 + 半透明格子」的组合。

**本机复验**：Rust 37 测试全绿、`verify_data.py` 2311 项通过、
Dart 词法括号检查通过；项目 / 上传包逐字节一致；三份 `main.yml` 未改。
**Dart 编译与两端打包仍只认下一轮 CI run**，本机无 Flutter/Dart。

### 第六轮：整屏推入动画，保留滑动且消除残影（2026-11-10 14:38）

用户明确纠正：「退回版本没有测试必要，你需要的是调整和优化滚动动画。」
因此既不是恢复第四轮，也不是停在第五轮，而是**改掉动画的结构**。

| 第四轮（有残影） | 第六轮（本次） |
|---|---|
| 位移 0.12 屏，两页几乎完全重合 | 位移 **1.0 整屏**，两页首尾衔接、任意时刻不重叠 |
| `FadeTransition` 交叉淡入，两页同时半透明 | **无任何淡入 / 透明度动画**，两页始终不透明 |
| 格子底色半透明，下层文字透出 | 每页 `DecoratedBox` 不透明底 + `ClipRect` 裁剪 |
| `easeOutCubic`（不对称） | `Curves.easeInOut` 中心对称，入 / 出两页速度一致 |
| 无独立重绘层 | `RepaintBoundary` 独立重绘，避免脏矩形残留 |

方向口径不变：**下滚 → 去下个月 → 新页自下方整屏推入、旧页被推向上方**；
上滚完全相反；点箭头、点标题跳年月按目标先后同向。仍是 220ms 一次性，
`_shownMonthKey` 绑定真实到位的数据，换月不再闪转圈，`_loadSeq` 丢弃
连滚中间请求。静止时 controller 完成、Ticker 静默、无帧回调。

`CalendarMotion.pageOffset()` 是可测的位移口径；Dart 测试 25 → **28**
（4 个整屏推入测试：时长 / 幅度、下滚衔接、上滚反向、源码级防残影约束；
最后一个断言禁止 `FadeTransition(` / `AnimatedOpacity(`，并要求
`ClipRect(` / `RepaintBoundary(` / `DecoratedBox(` / `easeInOut` 存在）。

**本机复验**：Rust 37 测试全绿、`verify_data.py` 2311 项、Dart 词法括号检查；
项目 / 上传包逐字节一致；三份 `main.yml` 未改。
**动画观感与 Dart 编译仍只认下一轮 CI run + 双端实机**，本机无 Flutter/Dart；
这次是结构性改动，必须两端各看一次再下结论，不得说「应该没残影了」。

## 已知风险（不得靠推测下结论）

1. **UOS 20 图形栈（已实机验证，风险关闭）**：16:37 复跑中 Flutter 窗口正常弹出、
   EGL/GL 初始化无报错、翻月与拉高窗口自适应正常、显卡驱动仅打印无害警告。
   此前「须真正跑起应用才能确认」的盲区已消除，见上节复跑表。
2. **glibc 兼容（构建与实机均已解决，风险关闭）**：UOS 20 为 glibc 2.28.36-deepin1；
   Ubuntu 22.04（2.35）产物曾报 `GLIBC_2.34 not found`。musl 静态 `cn_cal_cli`
   与 Debian 10 容器内重编的 runner 已在 UOS 实机跑通，`ldd` 无 not found、
   `objdump` 断言通过。唯一遗留是**升级 Flutter 版本时必须重新确认 runner 的
   glibc 符号上限**，CI 的 `objdump` 断言会拦住，见 `packaging/uos/README.md`。
3. **非 x86 架构**：Flutter 无 loongarch64 / sw64 官方引擎，若需覆盖须改用 Qt 重写 UI 层；
   计算核心已解耦，不受影响。
4. **Dart 代码**：本机无 Flutter/Dart，静态检查与构建结论以 CI run 为准。
5. **Windows 构建机固定为 `windows-2022`**：Flutter 3.22 的 `cmakeGenerator` 只识别
   VS 2022（major 17）；GitHub 自 2026-06 起把 `windows-latest` / `windows-2025`
   默认镜像换成 VS 2026（18.x），Flutter 会退化到 `Visual Studio 16 2019` 生成器，
   CMake 报 `could not find any instance of Visual Studio`。设 `CMAKE_GENERATOR`
   环境变量无效（Flutter 显式传 `-G`）。`build-windows` 因此固定 `windows-2022`
   （VS 2022 17.14，GitHub 官方缓解方案，见 `actions/runner-images#14017`），
   并在构建前用 vswhere 校验主版本为 17。升级到支持 major 18 的 Flutter 版本之前，
   不要改回 `windows-latest`。
6. **资源占用（UOS 多轮实测，Win10 GUI 采样未完成、24h 曲线未量）**：
   UOS 20 从初测 81–86 MB 到第 8 步 97,896 KB，每轮静止 60 秒只涨 0～8 KB、
   静止 CPU 1.5%～1.9%，无持续爬升；Win10 侧本机 GUI 采样因窗口在 60 秒内
   被关闭而中断，**未取得数据，不编造**；CLI 侧数据与 UTF-8 已自测通过。
   P2 常驻挂件上线前必须补齐两台机器连续 24 小时曲线。
   见 `docs/资源占用规范.md`、`docs/正式版验收结论.md`。
7. **P2 第 1 步的 Win10 鼠标钩子（已实机通过，风险关闭；保留长期回归提醒）**：
   C++ 编译 / 链接 / 打包由 run #14 证实通过；2026-11-11 实机确认点任务栏时间
   能弹出本软件月历，取消「接管任务栏时间」后系统自带日历恢复，托盘兜底可用。
   该钩子依赖 `TrayClockWClass` 等任务栏实现细节，微软未公开支持，Win10 大版本
   更新或安全软件拦截仍可能让它失效，届时按托盘菜单关掉开关即可，日历数据不受
   影响；每次 Win10 大版本更新后建议回归一次。仍未量的是双端 24h 资源曲线。
   见 `docs/P2第一步_Win10托盘与时间接管.md`。
8. **P2 第 2 步的 Win10 桌面挂件（待 CI + 实机验收）**：`HWND_BOTTOM` 依赖
   Windows Z 序，若被壁纸 / 图标盖住需升级为 `SetParent` 到桌面 `WorkerW`
   （涉及未公开消息，暂不引入）；`dart:ffi` 加载 `user32.dll`、离屏渲染的
   中文字体、`rawRgba` 通道顺序、gdi32 / user32 链接都只认 CI run；
   挂件固定 448×424 逻辑像素，未做高 DPI 缩放。挂件是纯增强能力，
   失败一律静默降级，主界面与托盘不受影响。见 `docs/P2第二步_Win10桌面挂件.md`。

## 详细文档

- `docs/方案定稿.md` — 技术栈裁决、架构分层、分阶段与验收口径
- `docs/数据规范.md` — 四层 schema、合并优先级、更新契约、DayInfo 输出
- `docs/数据核对规范.md` — 联网核对项、差异分级、报告契约
- `docs/资源占用规范.md` — 目标机器画像、双端资源实测、定期校准与低资源设计约束
- `docs/正式版验收结论.md` — v0.1.0 定稿记录：两端验收、精确性基线、交付物、遗留
- `docs/P2桌面形态方案.md` — 四条新需求对照、任务栏时间入口、开机自启、桌面挂件两端方案
- `docs/P2第一步_Win10托盘与时间接管.md` — P2 第 1 步的 runner 补丁架构、兜底与验收步骤
- `docs/P2第二步_Win10桌面挂件.md` — P2 第 2 步的离屏位图契约、分层置底窗口、低资源口径与 8 条验收
