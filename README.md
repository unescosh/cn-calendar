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
| **P0 完成** | 四层数据、Rust 计算核心、CLI、测试与校验脚本 | 本机实跑：34 个 Rust 测试 + 2183 项数据校验 + 联网核对全通过 |
| **P1 骨架完成** | Flutter 最小月历界面、静默更新器、核对服务、CI、打包模板 | Dart 侧**未经本地编译**（无 Flutter/Dart 工具链），结论以 CI run 为准 |
| **P2 计划** | 桌面透明挂件、托盘常驻、FFI 替换 CLI 桥接、UOS 实机验证 | 未开始 |

> 本机环境：`rustc 1.98.0` 可用；`flutter` / `dart` / Linux 构建工具链不可用。
> 因此 Rust 部分以本机 `cargo test` 为准，Flutter 与双端打包部分只认 CI。

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
.github/workflows/ci.yml   CI：数据/核心/联网核对/静态检查/双端构建
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

## 已知风险（不得靠推测下结论）

1. **UOS 20 图形栈**：老显卡 / 国产驱动可能只有软件渲染，Flutter Linux 的 EGL/GL 初始化需实机验证。
2. **glibc 兼容**：Ubuntu 22.04（2.35）产物不能在 UOS 20（2.28）跑，正式 deb 必须在
   Debian 10 容器或 UOS 实机构建，见 `packaging/uos/README.md`。
3. **非 x86 架构**：Flutter 无 loongarch64 / sw64 官方引擎，若需覆盖须改用 Qt 重写 UI 层；
   计算核心已解耦，不受影响。
4. **Dart 代码**：本机无 Flutter/Dart，静态检查与构建结论以 CI run 为准。

## 详细文档

- `docs/方案定稿.md` — 技术栈裁决、架构分层、分阶段与验收口径
- `docs/数据规范.md` — 四层 schema、合并优先级、更新契约、DayInfo 输出
- `docs/数据核对规范.md` — 联网核对项、差异分级、报告契约
