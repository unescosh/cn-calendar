#!/bin/sh
# 用户级安装：不需要 root、不改系统目录，适合不方便用 sudo 的办公机。
# 装到 ~/.local/share/cn-calendar，开机自启走标准 XDG autostart。
# 用法：sh install-user.sh <bundle 目录>
set -eu
SRC="${1:?用法: sh install-user.sh <bundle 目录>}"
if [ ! -f "$SRC/cn_calendar" ]; then
  echo "找不到 $SRC/cn_calendar" >&2
  exit 1
fi
if [ ! -f "$SRC/cn_cal_cli" ]; then
  echo "找不到 $SRC/cn_cal_cli（需 CI 组装好的 bundle）" >&2
  exit 1
fi

BASE="$HOME/.local/share/cn-calendar"
BIN="$HOME/.local/bin"
mkdir -p "$BASE" "$BIN" "$HOME/.local/share/applications" "$HOME/.config/autostart"
cp -a "$SRC/." "$BASE/"
chmod +x "$BASE/cn_calendar" "$BASE/cn_cal_cli"

cat > "$BIN/cn-calendar" <<'LAUNCHER'
#!/bin/sh
BASE="$HOME/.local/share/cn-calendar"
cd "$BASE" || exit 1
export LD_LIBRARY_PATH="$BASE/lib:${LD_LIBRARY_PATH:-}"
export CN_CAL_CLI="$BASE/cn_cal_cli"
exec "$BASE/cn_calendar" "$@"
LAUNCHER
chmod +x "$BIN/cn-calendar"

printf '%s\n' \
  '[Desktop Entry]' \
  'Type=Application' \
  'Name=中国日历' \
  'Name[zh_CN]=中国日历' \
  'Comment=离线优先的中国桌面日历' \
  "Exec=$BIN/cn-calendar" \
  'Icon=utilities-calendar' \
  'Terminal=false' \
  'Categories=Utility;Calendar;' \
  > "$HOME/.local/share/applications/cn-calendar.desktop"

cp "$HOME/.local/share/applications/cn-calendar.desktop" \
   "$HOME/.config/autostart/cn-calendar.desktop"
printf '%s\n' 'NoDisplay=true' 'X-GNOME-Autostart-enabled=true' \
  >> "$HOME/.config/autostart/cn-calendar.desktop"

echo "已安装到：$BASE"
echo "启动器：  $BIN/cn-calendar"
echo "开机自启：$HOME/.config/autostart/cn-calendar.desktop"
echo "取消自启：删除上面这个 autostart 文件即可（不动系统设置）。"
