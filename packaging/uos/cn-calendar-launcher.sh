#!/bin/sh
# UOS / Debian 启动包装：runner 用 $ORIGIN/lib 找 Flutter 引擎，
# cn_cal_cli 默认与 resolvedExecutable 同目录；这里再显式兜底一次。
BASE=/opt/cn-calendar
cd "$BASE" || exit 1
export LD_LIBRARY_PATH="$BASE/lib:${LD_LIBRARY_PATH:-}"
export CN_CAL_CLI="$BASE/cn_cal_cli"
exec "$BASE/cn_calendar" "$@"
