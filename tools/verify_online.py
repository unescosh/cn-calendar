#!/usr/bin/env python3
"""联网核对：本地计算结果 ↔ 权威时间基准 ↔ 上游调休数据。

    python tools/verify_online.py
    python tools/verify_online.py --cache C:/Temp/cncal-cache --cli <cn_cal_cli 路径>

设计要点见 docs/数据核对规范.md：
  - L1/L2/L3 由本地算法决定，联网数据只校验、不改写
  - 只有 L4 调休写入缓存；写入前先出差异报告
  - HTTP Date 头作为日期/星期基准，不需要专用时间 API
  - 网络不可用 -> status=offline，退出码 0；发现差异 -> 退出码 2
"""
from __future__ import annotations

import argparse
import datetime as dt
import email.utils
import json
import os
import subprocess
import sys
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
DATA = ROOT / "data"
SOURCES = [
    "https://www.gov.cn/",
    "https://www.baidu.com/",
    "https://cdn.jsdelivr.net/gh/NateScarlet/holiday-cn@master/",
    "https://raw.githubusercontent.com/",
]
UPSTREAM_HOLIDAY = [
    "https://cdn.jsdelivr.net/gh/NateScarlet/holiday-cn@master/{year}.json",
    "https://raw.githubusercontent.com/NateScarlet/holiday-cn/master/{year}.json",
]
NATIONAL_DAYS = {
    "09-03": "中国人民抗日战争胜利纪念日",
    "09-30": "烈士纪念日",
    "12-04": "国家宪法日",
    "12-13": "南京大屠杀死难者国家公祭日",
}


def find_cli(explicit: str | None) -> Path | None:
    if explicit:
        return Path(explicit)
    env = os.environ.get("CN_CAL_CLI")
    if env:
        return Path(env)
    for base in (ROOT / "core" / "target" / "debug", ROOT / "core" / "target" / "release"):
        for name in ("cn_cal_cli.exe", "cn_cal_cli"):
            p = base / name
            if p.exists():
                return p
    return None


def cli_json(cli: Path, args: list[str], differences: list[dict]) -> dict | list | None:
    try:
        r = subprocess.run(
            [str(cli), *args], capture_output=True, text=True,
            encoding="utf-8", timeout=30, check=False,
        )
        if r.returncode != 0:
            differences.append({"id": "cli_error", "detail": f"{' '.join(args)}: {r.stderr.strip()}"})
            return None
        return json.loads(r.stdout)
    except Exception as e:  # noqa: BLE001
        differences.append({"id": "cli_error", "detail": f"{' '.join(args)}: {e}"})
        return None


def http_date_headers() -> list[tuple[str, dt.datetime]]:
    """收集各 HTTP 源的 Date 响应头，返回 (源, UTC 时间)。"""
    out: list[tuple[str, dt.datetime]] = []
    for url in SOURCES:
        try:
            req = urllib.request.Request(url, method="HEAD", headers={"User-Agent": "cn-calendar-verify/1"})
            with urllib.request.urlopen(req, timeout=8) as resp:
                raw = resp.headers.get("Date")
                if raw:
                    parsed = email.utils.parsedate_to_datetime(raw)
                    if parsed.tzinfo is None:
                        parsed = parsed.replace(tzinfo=dt.timezone.utc)
                    out.append((url, parsed.astimezone(dt.timezone.utc)))
        except Exception:  # noqa: BLE001  任一源失败就换下一个
            continue
    return out


def fetch_upstream(year: int) -> tuple[str, str] | None:
    for tpl in UPSTREAM_HOLIDAY:
        url = tpl.format(year=year)
        try:
            req = urllib.request.Request(url, headers={"User-Agent": "cn-calendar-verify/1"})
            with urllib.request.urlopen(req, timeout=10) as resp:
                if resp.status != 200:
                    continue
                return url, resp.read().decode("utf-8")
        except Exception:  # noqa: BLE001
            continue
    return None


def valid_upstream(text: str, year: int) -> bool:
    try:
        j = json.loads(text)
        if j.get("year") != year:
            return False
        days = j.get("days")
        if not isinstance(days, list) or not days:
            return False
        for x in days:
            if not isinstance(x, dict) or not str(x.get("date", "")).startswith(f"{year}-"):
                return False
            if not isinstance(x.get("isOffDay"), bool):
                return False
            dt.date.fromisoformat(x["date"])
        return True
    except Exception:  # noqa: BLE001
        return False


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--cache", default=os.environ.get("CN_CAL_HOLIDAY_DIR", "C:/Temp/cncal-cache"))
    ap.add_argument("--cli", default=None)
    ap.add_argument("--years", default="2025,2026,2027")
    args = ap.parse_args()

    cache = Path(args.cache)
    cache.mkdir(parents=True, exist_ok=True)
    cli = find_cli(args.cli)
    years = [int(x) for x in args.years.split(",")]

    checks: list[dict] = []
    differences: list[dict] = []
    sources: list[str] = []
    now_utc = dt.datetime.now(dt.timezone.utc)

    # 1) HTTP Date 头：权威日期与星期基准
    headers = http_date_headers()
    if headers:
        remote = headers[0][1]
        sources = [u for u, _ in headers]
        # 统一到 0=周日 … 6=周六
        remote_wd = (remote.weekday() + 1) % 7
        local_wd = (now_utc.weekday() + 1) % 7
        if remote.date() != now_utc.date():
            differences.append({
                "id": "clock_skew",
                "date": now_utc.date().isoformat(),
                "detail": f"本机 UTC 日期 {now_utc.date()} 与 HTTP Date 头 {remote.date()} 不符",
            })
        if cli:
            local = cli_json(cli, ["day", now_utc.date().isoformat()], differences)
            if isinstance(local, dict):
                if local.get("weekday") != remote_wd:
                    differences.append({
                        "id": "weekday_mismatch",
                        "date": now_utc.date().isoformat(),
                        "detail": f"本地算法星期 {local.get('weekday')} 与权威基准 {remote_wd} 不符",
                    })
                if local.get("date") != now_utc.date().isoformat():
                    differences.append({
                        "id": "clock_skew", "date": now_utc.date().isoformat(),
                        "detail": "核心返回的日期与请求日期不一致",
                    })
        checks.append({
            "id": "http-date-weekday",
            "status": "ok" if not any(d["id"] in ("clock_skew", "weekday_mismatch") for d in differences) else "diff",
            "detail": f"{len(headers)} 个 HTTP 源，Date 头 {remote.isoformat()}，"
                      f"权威星期 {remote_wd}，本机星期 {local_wd}",
        })
    else:
        checks.append({"id": "http-date-weekday", "status": "skipped", "detail": "网络不可用，跳过在线基准"})

    # 2) 本地公历/星期算法自洽（断网也跑）
    if cli:
        wd = cli_json(cli, ["verify", "weekday", "2020", "2050"], differences)
        if isinstance(wd, dict):
            ok = bool(wd.get("consistent"))
            if not ok:
                differences.append({"id": "weekday_mismatch", "detail": f"星期连续性异常：{wd.get('mismatches')}"})
            checks.append({"id": "weekday-continuity", "status": "ok" if ok else "diff",
                           "detail": f"{wd.get('days')} 天往返与星期循环检查"})
    else:
        checks.append({"id": "weekday-continuity", "status": "skipped", "detail": "未找到 cn_cal_cli"})

    # 3) L4 上游比对 + 写入缓存（唯一允许更新的层）
    online_ok = False
    upstream_by_year: dict[int, dict] = {}
    for year in years:
        got = fetch_upstream(year)
        if not got:
            checks.append({"id": f"holiday-{year}", "status": "skipped", "detail": "上游不可达"})
            continue
        url, text = got
        online_ok = True
        if not valid_upstream(text, year):
            differences.append({"id": "holiday_changed", "detail": f"{year} 年上游数据校验失败，已丢弃"})
            checks.append({"id": f"holiday-{year}", "status": "diff", "detail": "上游 JSON 校验失败"})
            continue
        upstream_by_year[year] = json.loads(text)

        # 用 Rust 核心做纯函数比对，避免 Python 另写一套比较逻辑
        if cli:
            tmp = cache / f"_upstream-{year}.json"
            tmp.write_text(text, encoding="utf-8")
            report = cli_json(cli, ["verify", "holiday", str(year), str(tmp)], differences)
            # Path.unlink(missing_ok=...) 需要 Python 3.8+；UOS 20 自带 3.7
            try:
                tmp.unlink()
            except OSError:
                pass
            if isinstance(report, dict):
                for d in report.get("differences", []):
                    differences.append({
                        "id": f"holiday_{d['kind']}", "date": d["date"],
                        "detail": f"{year} 年内置 {d['builtin']} / 上游 {d['upstream']}",
                    })
                checks.append({
                    "id": f"holiday-{year}",
                    "status": "ok" if report.get("consistent") else "diff",
                    "detail": f"内置 {report.get('builtin_count')} 条 / 上游 {report.get('upstream_count')} 条，"
                              f"差异 {len(report.get('differences', []))} 处",
                })
        # 上游是 L4 唯一权威来源，写入缓存供核心启动时覆盖
        (cache / f"holiday-{year}.json").write_text(text, encoding="utf-8")

    # 4) 节日抽样核对：核对"更新后本地计算"与上游、固定纪念日是否一致
    if cli and upstream_by_year:
        sampling_issues = 0
        sampled = 0
        anchor_days = 0
        anchor_issues = 0
        anchor_supported = False
        for year, up in upstream_by_year.items():
            # 按月批量取，减少 CLI 进程启动次数
            months = sorted({int(x["date"][5:7]) for x in up["days"]})
            local_by_date: dict[str, dict] = {}
            for m in months:
                rows = cli_json(cli, ["month", str(year), str(m)], differences)
                if isinstance(rows, list):
                    for row in rows:
                        local_by_date[row["date"]] = row
            for x in up["days"]:
                date = x["date"]
                local = local_by_date.get(date)
                if not local:
                    sampling_issues += 1
                    differences.append({"id": "cli_error", "date": date, "detail": "本地未返回该日数据"})
                    continue
                sampled += 1
                if x["isOffDay"]:
                    if not local.get("rest") or local.get("workday"):
                        sampling_issues += 1
                        differences.append({"id": "priority_mismatch", "date": date,
                                            "detail": f"上游为法定休，本地却判定 workday={local.get('workday')}"})
                else:
                    if not local.get("makeup") or not local.get("workday"):
                        sampling_issues += 1
                        differences.append({"id": "priority_mismatch", "date": date,
                                            "detail": f"上游为补班，本地却判定 makeup={local.get('makeup')}"})
            # 四个国家级纪念日：必须由本地 L1 给出，与联网数据无关
            for md, name in NATIONAL_DAYS.items():
                date = f"{year}-{md}"
                rows = cli_json(cli, ["day", date], differences)
                if isinstance(rows, dict) and not any(
                    l.get("name") == name for l in rows.get("labels", [])
                ):
                    sampling_issues += 1
                    differences.append({"id": "festival_missing", "date": date, "detail": f"本地缺少 {name}"})
            # 4b) 逐年核对节日正日：放假区间里只有正日可以带节名标签。
            # 旧版核心没有 festival_day 字段时整段跳过，不误报。
            for date, local in local_by_date.items():
                if "festival_day" not in local:
                    continue
                anchor_supported = True
                if local.get("festival_day"):
                    anchor_days += 1
                    if not local.get("labels"):
                        anchor_issues += 1
                        sampling_issues += 1
                        differences.append({
                            "id": "festival_anchor_missing_label",
                            "date": date,
                            "detail": "节日正日却没有节名标签",
                        })
        if anchor_supported:
            checks.append({
                "id": "festival-anchor",
                "status": "ok" if anchor_issues == 0 else "diff",
                "detail": f"核对 {anchor_days} 个节日正日，漏标 {anchor_issues} 处",
            })
        checks.append({
            "id": "festival-sampling",
            "status": "ok" if sampling_issues == 0 else "diff",
            "detail": f"核对 {sampled} 条调休日 + {len(years) * 4} 个国家级纪念日，问题 {sampling_issues} 处",
        })

    if not headers and not online_ok:
        status = "offline"
    elif differences:
        status = "differences"
    else:
        status = "consistent"

    report = {
        "checked_at": now_utc.isoformat(),
        "mode": "online-verify",
        "status": status,
        "sources": sources,
        "checks": checks,
        "differences": differences,
        "notes": ["本地 L1/L2/L3 未被联网数据改写", "仅 L4 调休写入缓存供核心覆盖"],
    }
    out = cache / "verify-report.json"
    out.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")

    print(f"状态: {status}")
    for c in checks:
        print(f"  [{c['status']:>7}] {c['id']}: {c['detail']}")
    if differences:
        print(f"差异 {len(differences)} 处：")
        for d in differences[:12]:
            print("  -", d["id"], d.get("date", ""), d["detail"])
    print(f"报告: {out}")
    return 2 if status == "differences" else 0


if __name__ == "__main__":
    sys.exit(main())
