# 统信 UOS 20 打包说明

目标环境：统信桌面操作系统 V20（1070），内核 4.19，glibc 2.28，DDE/Qt 桌面，x86_64。

## 关键约束：glibc 版本只能向下兼容

**在 glibc 2.35（Ubuntu 22.04）或更高版本上编译的 Flutter/原生产物，无法在 UOS 20（2.28）上运行**，
会报 `GLIBC_2.34 not found` 之类错误。CI 里的 `build-linux-bundle` job 只用于验证 Linux 侧代码能编译，
其产物**不可**直接发给 UOS 用户。

正式包必须在以下之一构建：

1. UOS 20 实机（最可靠，顺带完成实机图形栈验证）
2. Debian 10 (buster) 容器，glibc 2.28，与目标一致

## 在 UOS 20 实机构建

```bash
# 1) 系统依赖（Flutter Linux 桌面）
sudo apt install -y clang cmake ninja-build pkg-config libgtk-3-dev \
                    liblzma-dev libglu1-mesa git curl unzip xz-utils zip

# 2) Flutter 3.22 SDK（若系统源版本过旧，用官方 tar 包）
#    https://docs.flutter.dev/get-started/install/linux/desktop

# 3) 生成平台壳并构建
cd app
flutter create --platforms=linux --project-name cn_calendar --org cn.calendar .
flutter pub get
flutter build linux --release

# 4) Rust 计算核心与 CLI（零外部依赖，可离线）
cd ../core
cargo build --release --offline --bin cn_cal_cli

# 5) 打 deb
cd ..
bash packaging/uos/build_deb.sh
```

> 注意：Flutter 官方 Linux 桌面**构建**环境要求 Debian 11+ / Ubuntu 20.04+，
> 而 UOS 20 是 Debian 10 系。若 `flutter build linux` 因 clang/cmake/libstdc++ 版本过旧失败，
> 需要手动升级这些开发工具（不影响运行时 glibc）。这一步**必须实机验证**，不能靠推测。

## 图形栈验证清单（UOS 实机）

- [ ] 首屏正常渲染，无黑屏/花屏
- [ ] 老显卡 / 软件渲染下可用（必要时设置 `FLUTTER_GPU_DISABLE=true` 或软件渲染回退）
- [ ] X11 与 Wayland 会话分别验证；DDE 默认以 X11 为主
- [ ] 中文字体与输入法（fcitx）正常
- [ ] `cn_cal_cli` 与主程序同目录，desktop 文件的 `CN_CAL_CLI` 生效
- [ ] 断网启动仍显示烈士纪念日、农历、节气（仅当年新调休缺失）

## 多架构扩展

若后续需要 arm64（飞腾/鲲鹏），Flutter 有官方 arm64 引擎，可加交叉编译 job；
若是 loongarch64 / sw64，Flutter 无官方产物，须改用 Qt 5.15 重写 UI 层——
计算核心已独立成 `cn_cal_core` crate，与 UI 解耦，不受影响。

## 安装与卸载

```bash
sudo dpkg -i dist/cn-calendar_0.1.0_amd64.deb
sudo apt-get -f install          # 补齐依赖
sudo dpkg -r cn-calendar
```

运行时缓存目录为 `~/.cn_calendar/cache`，存放年度调休 JSON 与 `verify-report.json`。
卸载不会自动清理该目录，属用户数据。
