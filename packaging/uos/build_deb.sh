#!/usr/bin/env bash
# 组装面向统信 UOS 20（amd64, glibc 2.28, 内核 4.19）的 deb 包。
#
# 前置条件（重要）：Flutter bundle 与 cn_cal_cli 必须在 glibc <= 2.28 的环境构建。
# 在 Ubuntu 22.04（glibc 2.35）编出的产物装到 UOS 20 会因 GLIBC 版本过高而失败。
# 推荐在 UOS 20 实机或 Debian 10 容器中构建，详见同目录 README.md。
#
# 用法：
#   ./build_deb.sh [flutter bundle 路径] [cn_cal_cli 路径]
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
BUNDLE="${1:-$ROOT/app/build/linux/x64/release/bundle}"
CLI="${2:-$ROOT/core/target/release/cn_cal_cli}"
OUT="$ROOT/dist"

if [[ ! -d "$BUNDLE" ]]; then
  echo "找不到 Flutter bundle: $BUNDLE" >&2
  exit 1
fi
if [[ ! -f "$CLI" ]]; then
  echo "找不到 cn_cal_cli: $CLI" >&2
  exit 1
fi

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

mkdir -p "$STAGE/DEBIAN" \
         "$STAGE/opt/cn-calendar" \
         "$STAGE/usr/share/applications" \
         "$STAGE/usr/share/icons/hicolor/256x256/apps" \
         "$STAGE/usr/bin" \
         "$OUT"

cp "$HERE/DEBIAN/control" "$STAGE/DEBIAN/control"
cp "$HERE/cn-calendar.desktop" "$STAGE/usr/share/applications/cn-calendar.desktop"
cp -a "$BUNDLE/." "$STAGE/opt/cn-calendar/"
cp "$CLI" "$STAGE/opt/cn-calendar/cn_cal_cli"
chmod +x "$STAGE/opt/cn-calendar/cn_cal_cli"
ln -s /opt/cn-calendar/cn_calendar "$STAGE/usr/bin/cn-calendar"

DEB="$OUT/cn-calendar_0.1.0_amd64.deb"
dpkg-deb --build "$STAGE" "$DEB"
echo "已生成 $DEB"
echo "安装后请确认：/opt/cn-calendar/cn_cal_cli 可执行，且 CN_CAL_CLI 由 desktop 文件注入。"
