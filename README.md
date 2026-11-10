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
| **P2 计划** | 任务栏时间入口、开机自启、桌面挂件、托盘常驻、FFI 替换 CLI 桥接 | 方案已定（`docs/P2桌面形态方案.md`），代码未开始 |
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
  tests/core_tests.rs       21 个集成测试（含 2020–2050 全范围连续性）
app/                       Flutter 3.22 最小界面（P1 骨架）
tools/                     数据生成、自洽校验、联网核对
docs/                      方案定稿、数据规范、核对规范
packaging/uos/             UOS 20 deb 打包模板与实机验证清单
reports/                   核对报告与 UOS 实机留档（含机器路径的文件已 .gitignore）
.github/workflows/ci.yml   CI：数据/核心/联网核对/静态检查/双端构建/UOS 静态核心
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

**尚未验收**：Win10 侧资源未测，24 小时内存漂移曲线未量；
本机无 Flutter/Dart，本轮界面与策略改动的静态检查、16 个测试只认 CI run。

## 用户追加需求（2026-11-09 16:59）

| # | 要求 | 裁决 / 状态 |
|---|---|---|
| 1 | 点击任务栏日历/时间弹出的界面就是本软件界面；不必真正替换系统自带日历，效果满足即可 | 采纳「接管入口、不碰系统组件」，方案见 `docs/P2桌面形态方案.md`，**代码待 P2 实现** |
| 2 | 常驻后台 + 桌面插件；更新不要太频繁，固定/提前定好的数据只需定期校准，但必须精准 | **已落地**：7 天核对、分季节同步、手动立即校准、本地计算不降频 |
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

**尚未验收**：两个安装包都未在目标机实机安装。UOS 侧本轮只验证到
「自启项已落地、用它的 Exec 能弹出窗口」，不重启/注销办公机，
真正重启自启由用户下次开机确认；Win10 侧绿色包首次运行与资源占用同样待实测。
给 UOS 的实机指令见本机 `给UOS的第5步_安装验证.txt`（Downloads 目录，不进仓库）。

**P2 仍未实现**：点任务栏时间弹出本软件界面（Win10 托盘 + 鼠标钩子 /
UOS DDE Dock 插件）、桌面透明挂件、托盘月历、FFI 替换 CLI 桥接。
方案见 `docs/P2桌面形态方案.md`；本轮只完成打包级自启，
挂件与入口接管上线时会与主窗口共用同一进程，不新增常驻进程。

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
6. **资源占用（UOS 已初测，Win10 与长时曲线待测）**：UOS 20 的 71 秒初测为
   81–86 MB、静止 CPU 1.3%，无持续爬升；但 Win10 侧未测、24 小时内存漂移未量，
   P2 常驻挂件上线前必须补齐两台机器连续 24 小时的曲线。见 `docs/资源占用规范.md`。

## 详细文档

- `docs/方案定稿.md` — 技术栈裁决、架构分层、分阶段与验收口径
- `docs/数据规范.md` — 四层 schema、合并优先级、更新契约、DayInfo 输出
- `docs/数据核对规范.md` — 联网核对项、差异分级、报告契约
- `docs/资源占用规范.md` — 目标机器画像、双端资源实测、定期校准与低资源设计约束
- `docs/P2桌面形态方案.md` — 四条新需求对照、任务栏时间入口、开机自启、桌面挂件两端方案
