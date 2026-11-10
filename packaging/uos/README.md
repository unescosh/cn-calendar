# 统信 UOS 20 打包说明

目标环境：统信桌面操作系统 V20（1070），内核 4.19，glibc 2.28，DDE/X11，x86_64。
**界面已在该实机跑通**（2026-11-09 16:37 与 17:38 两轮复跑），当前 CI 可自动产出 deb。

## 关键约束：glibc 版本只能向下兼容

**在 glibc 2.35（Ubuntu 22.04）或更高版本上编译的 Flutter/原生产物，无法在 UOS 20（2.28）上运行**，
会报 `GLIBC_2.34 not found`。CI 里的 `build-linux-bundle` 只验证 Linux 侧能编译，
其产物**不可**发给 UOS 用户。

正式包链路（CI `build-uos20-bundle`）：

1. Debian 10（glibc 2.28）容器内 `flutter build linux --release`
2. musl 静态 `cn_cal_cli` 由 CI 填进 bundle
3. `objdump -T` 断言 runner 最高 glibc 符号不超过 2.28
4. 同 job 末尾用 `packaging/uos/build_deb.sh` 打成 deb

> `dpkg-deb` **只打包、不编译**，所以组装步骤可以在 ubuntu-22.04 上做：
> 包内二进制仍是 glibc 2.28 产物，装到 UOS 20 不会报 GLIBC 版本错误。

## 自动打包（推荐）

CI 会校验 deb 内含主程序、静态 CLI、`/usr/bin/cn-calendar` 启动器与
`/etc/xdg/autostart/cn-calendar.desktop`，并上传 artifact `cn-calendar-uos20-deb`。
无需在 UOS 上安装任何开发工具。

## 手动打包

```bash
bash packaging/uos/build_deb.sh <bundle 目录> [输出 deb 路径]
# bundle 内应有 cn_calendar、cn_cal_cli、lib/、data/
# 默认输出 dist/cn-calendar_0.1.0_amd64.deb
```

## 安装

```bash
sudo dpkg -i cn-calendar_0.1.0_amd64.deb
sudo apt-get -f install          # 若源里依赖名不一致，补齐依赖
sudo dpkg -r cn-calendar         # 卸载
```

`Depends` 写的是 Debian 10 标准包名。实机体检已确认 `libgtk-3.so.0`、
`libGL.so.1`、`libX11.so.6` 全部存在；若 UOS 定制源解析不了某个依赖名，
可用下面这条兜底（不会绕过真正的运行库检查，只是跳过包名解析）：

```bash
sudo dpkg -i --force-depends cn-calendar_0.1.0_amd64.deb
```

## 开机自启（用户明确要求）

deb 会安装 `/etc/xdg/autostart/cn-calendar.desktop`（XDG 标准，登录桌面后自动启动）。
包内同时装了：

| 路径 | 作用 |
|---|---|
| `/opt/cn-calendar/` | 主程序、静态 CLI、`lib/`、`data/` |
| `/usr/bin/cn-calendar` | 启动包装脚本，设好 `LD_LIBRARY_PATH` 与 `CN_CAL_CLI` |
| `/usr/share/applications/cn-calendar.desktop` | 启动器图标 |
| `/usr/share/icons/hicolor/scalable/apps/cn-calendar.svg` | 日历图标 |
| `/etc/xdg/autostart/cn-calendar.desktop` | 登录时自启 |

取消自启（二选一，都不动其他系统设置）：

```bash
sudo rm /etc/xdg/autostart/cn-calendar.desktop
# 或在用户级覆盖：~/.config/autostart/cn-calendar.desktop 里写 Hidden=true
```

## 免 root 用户级安装（不方便 sudo 的办公机）

```bash
sh packaging/uos/install-user.sh <bundle 目录>
```

装到 `~/.local/share/cn-calendar`，启动器 `~/.local/bin/cn-calendar`，
自启项 `~/.config/autostart/cn-calendar.desktop`，**完全不改系统目录**。
取消自启只需删掉那个 autostart 文件。

## 图形栈验证清单（UOS 实机）

- [x] 首屏正常渲染，无黑屏/花屏
- [x] X11 / DDE 下可用，显卡硬件加速正常（Glenfly Arise1020 / OpenGL 4.5 / Mesa 25.00.58）
- [x] 中文字体、农历、节气、节日角标显示正常
- [x] `cn_cal_cli` 与主程序同目录，数据流连通（底部「数据核对一致」）
- [x] 9/30 烈士纪念日、休/班角标、整月一屏、四类配色与图例
- [x] 内存约 82.7 MB、静止 CPU 0.5%，60 秒仅涨 8 KB
- [ ] Wayland 会话（DDE 默认 X11，暂不覆盖）
- [ ] 断网启动（本地数据内置，预计通过，待实机确认）

## 多架构扩展

若后续需要 arm64（飞腾/鲲鹏），Flutter 有官方 arm64 引擎，可加交叉编译 job；
若是 loongarch64 / sw64，Flutter 无官方产物，须改用 Qt 5.15 重写 UI 层——
计算核心已独立成 `cn_cal_core` crate，与 UI 解耦，不受影响。

运行时缓存目录为 `~/.cn_calendar/cache`，存放年度调休 JSON 与 `verify-report.json`。
卸载不会自动清理该目录，属用户数据。
