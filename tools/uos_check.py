#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""零依赖环境体检，Windows 与统信 UOS 20 均可运行，兼容 Python 3.7+。

用法（在 UOS 上，把项目文件夹放好后）：
    python3 tools/uos_check.py

输出：当前目录 uos-check-report.json + 中文摘要。
把那个 json 文件发回给 Windows 上的 WorkBuddy，就能据此判断这台机器能不能跑。
全程不装任何东西、不改任何系统设置。
"""
import datetime
import json
import os
import platform
import shutil
import subprocess
from pathlib import Path


def sh(cmd, timeout=10):
    try:
        if isinstance(cmd, str):
            r = subprocess.run(cmd, shell=True, capture_output=True, text=True,
                               timeout=timeout)
        else:
            r = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
        return (r.stdout or "").strip() or (r.stderr or "").strip()
    except Exception:
        return ""


def first_line(s):
    lines = s.splitlines()
    return lines[0] if lines else ""


def main():
    rep = {}
    rep["checked_at"] = datetime.datetime.now().isoformat(timespec="seconds")
    rep["python"] = platform.python_version()
    rep["system"] = platform.system()
    rep["arch"] = platform.machine()
    is_linux = platform.system() == "Linux"

    if is_linux:
        osr = {}
        p = Path("/etc/os-release")
        if p.exists():
            for line in p.read_text(encoding="utf-8", errors="replace").splitlines():
                if "=" in line:
                    k, v = line.split("=", 1)
                    osr[k] = v.strip().strip('"')
        rep["os"] = {"name": osr.get("NAME", ""), "version": osr.get("VERSION", ""),
                     "id": osr.get("ID", "")}
        rep["kernel"] = platform.release()
        rep["glibc"] = first_line(sh(["ldd", "--version"]))
        rep["session"] = os.environ.get("XDG_SESSION_TYPE", "")
        rep["desktop"] = os.environ.get("XDG_CURRENT_DESKTOP", "")
        rep["display"] = os.environ.get("DISPLAY", "")
        rep["wayland_display"] = os.environ.get("WAYLAND_DISPLAY", "")
        ld = sh(["ldconfig", "-p"])
        rep["libs"] = {
            "libgtk-3": "libgtk-3.so.0" in ld,
            "libGL": "libGL.so.1" in ld,
            "libX11": "libX11.so.6" in ld,
        }
        rep["glxinfo"] = first_line(sh(["glxinfo", "-B"]))
    else:
        rep["os"] = {"name": platform.system() + " " + platform.release()}
        rep["libs"] = {}

    tools = ["rustc", "cargo", "flutter", "dart", "node", "npm", "git", "python3",
             "clang", "cmake", "ninja", "pkg-config", "dpkg-deb", "glxinfo"]
    rep["tools"] = {}
    for t in tools:
        rep["tools"][t] = shutil.which(t) or ""

    # 若已有编译好的 cn_cal_cli，顺手验证核心在本机是否算得对
    root = Path(__file__).resolve().parent.parent
    candidates = []
    env_cli = os.environ.get("CN_CAL_CLI")
    if env_cli:
        candidates.append(Path(env_cli))
    for name in ("cn_cal_cli.exe", "cn_cal_cli"):
        candidates.append(root / "core" / "target" / "release" / name)
        candidates.append(root / "core" / "target" / "debug" / name)
        candidates.append(root / name)
    cli = ""
    for c in candidates:
        if c.is_file():
            cli = str(c)
            break
    rep["cli"] = cli
    if cli:
        rep["core_day_ok"] = "烈士纪念日" in sh([cli, "day", "2026-09-30"])
        rep["core_weekday_ok"] = '"consistent":true' in sh([cli, "verify", "weekday"])
        rep["core_range"] = sh([cli, "range"])
    else:
        rep["core_day_ok"] = None
        rep["core_weekday_ok"] = None
        rep["core_range"] = ""

    advice = []
    if is_linux:
        if not rep["libs"].get("libgtk-3"):
            advice.append("缺 libgtk-3-0：Flutter 界面起不来，需 sudo apt install libgtk-3-0")
        if not rep["libs"].get("libGL"):
            advice.append("缺 libGL：需 libgl1 或显卡驱动，否则可能黑屏")
        if rep["session"] == "wayland":
            advice.append("当前是 Wayland 会话，Flutter 需额外验证；建议先用 X11 会话测试")
        if not rep["tools"].get("flutter"):
            advice.append("未装 Flutter SDK：界面需下载 CI 产物，或后续在 UOS 实机编译")
        if not rep["tools"].get("rustc"):
            advice.append("未装 Rust：可直接用 CI 预编译的 cn_cal_cli，不必自己编译")
        advice.append("glibc 决定能否运行 CI 产物：" + (rep["glibc"] or "未读到"))
        advice.append("若 CI 产物报 GLIBC_2.34 not found，说明产物 glibc 过高，须在 UOS 上重编")
    else:
        advice.append("这是 Windows 侧体检；请在 UOS 目标机器上运行同一脚本才有意义")
    rep["advice"] = advice

    out = Path("uos-check-report.json")
    out.write_text(json.dumps(rep, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")

    print("=== 环境体检摘要 ===")
    print("系统:", rep["os"].get("name"), rep["os"].get("version", ""))
    print("内核:", rep.get("kernel", "-"), "| 架构:", rep["arch"], "| Python:", rep["python"])
    print("glibc:", rep.get("glibc", "-"))
    print("桌面:", rep.get("desktop", "-"), "| 会话:", rep.get("session", "-"))
    if is_linux:
        print("关键库:", rep["libs"])
    print("已装工具:", ", ".join(sorted(k for k, v in rep["tools"].items() if v)) or "（无）")
    if cli:
        print("核心自检: 烈士纪念日 =", rep["core_day_ok"], "| 星期连续 =", rep["core_weekday_ok"])
    else:
        print("核心自检: 未找到 cn_cal_cli（可用 CI 产物）")
    for a in advice:
        print("提示:", a)
    print("报告已写入:", out.resolve())
    print("把 uos-check-report.json 发回给 Windows 上的 WorkBuddy 即可。")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
