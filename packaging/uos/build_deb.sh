#!/usr/bin/env bash
# 组装面向统信 UOS 20（amd64, glibc 2.28, 内核 4.19）的 deb 安装包。
#
# 前置条件：Flutter bundle 与 cn_cal_cli 必须在 glibc <= 2.28 环境构建。
# CI 的 build-uos20-bundle 已在 Debian 10 容器内重编界面，并把 musl 静态
# CLI 放进 bundle；本脚本只做打包（dpkg-deb 不编译），可在任意带 dpkg-deb
# 的机器上执行，产物仍能在 UOS 20 运行。
#
# 用法：
#   ./build_deb.sh <bundle 目录> [输出 deb 路径]
# bundle 内应有：cn_calendar、cn_cal_cli、lib/、data/
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
BUNDLE="${1:-$ROOT/app/build/linux/x64/release/bundle}"
OUT="${2:-$ROOT/dist/cn-calendar_0.1.0_amd64.deb}"

if [[ ! -f "$BUNDLE/cn_calendar" ]]; then
  echo "找不到主程序: $BUNDLE/cn_calendar" >&2
  exit 1
fi
if [[ ! -f "$BUNDLE/cn_cal_cli" ]]; then
  echo "找不到静态计算核心: $BUNDLE/cn_cal_cli" >&2
  echo "CI 的 build-uos20-bundle 会把 musl 静态 CLI 放进 bundle。" >&2
  exit 1
fi

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

mkdir -p "$STAGE/DEBIAN" \
         "$STAGE/opt/cn-calendar" \
         "$STAGE/usr/bin" \
         "$STAGE/usr/share/applications" \
         "$STAGE/usr/share/icons/hicolor/scalable/apps" \
         "$STAGE/etc/xdg/autostart" \
         "$(dirname "$OUT")"

cp "$HERE/DEBIAN/control" "$STAGE/DEBIAN/control"
cp "$HERE/cn-calendar.desktop" "$STAGE/usr/share/applications/cn-calendar.desktop"
cp "$HERE/cn-calendar-autostart.desktop" "$STAGE/etc/xdg/autostart/cn-calendar.desktop"
cp "$HERE/cn-calendar-launcher.sh" "$STAGE/usr/bin/cn-calendar"
cp "$HERE/cn-calendar.svg" "$STAGE/usr/share/icons/hicolor/scalable/apps/cn-calendar.svg"
cp -a "$BUNDLE/." "$STAGE/opt/cn-calendar/"

chmod 755 "$STAGE/usr/bin/cn-calendar" \
          "$STAGE/opt/cn-calendar/cn_calendar" \
          "$STAGE/opt/cn-calendar/cn_cal_cli"
chmod 644 "$STAGE/usr/share/applications/cn-calendar.desktop" \
          "$STAGE/etc/xdg/autostart/cn-calendar.desktop"

# 较新 dpkg 可用 --root-owner-group 保证包内文件属 root，避免安装时属主告警。
if dpkg-deb --help 2>&1 | grep -q -- '--root-owner-group'; then
  dpkg-deb --build --root-owner-group "$STAGE" "$OUT"
else
  dpkg-deb --build "$STAGE" "$OUT"
fi

echo "已生成 $OUT"
echo "包内含 /etc/xdg/autostart/cn-calendar.desktop（登录时自动启动）"
