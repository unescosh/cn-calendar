#!/usr/bin/env python3
"""独立校验 data/ 下所有日历数据的自洽性（不依赖 Rust 实现）。

用法：python tools/verify_data.py
CI 中作为门禁运行；任一项失败即退出码 1。
"""
from __future__ import annotations

import datetime as dt
import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
DATA = ROOT / "data"

JIEQI_ORDER = [
    "小寒", "大寒", "立春", "雨水", "惊蛰", "春分", "清明", "谷雨",
    "立夏", "小满", "芒种", "夏至", "小暑", "大暑", "立秋", "处暑",
    "白露", "秋分", "寒露", "霜降", "立冬", "小雪", "大雪", "冬至",
]
VALID_KINDS = {"节日", "国家级纪念日", "纪念日", "主题日", "法定假", "调休"}
NATIONAL_DAYS = {
    "09-03": "中国人民抗日战争胜利纪念日",
    "09-30": "烈士纪念日",
    "12-04": "国家宪法日",
    "12-13": "南京大屠杀死难者国家公祭日",
}

errors: list[str] = []
checks = 0


def check(cond: bool, msg: str) -> bool:
    global checks
    checks += 1
    if not cond:
        errors.append(msg)
    return cond


def load(name: str):
    p = DATA / name
    if not check(p.exists(), f"缺少文件 {name}"):
        return None
    try:
        return json.loads(p.read_text(encoding="utf-8"))
    except Exception as e:  # noqa: BLE001
        errors.append(f"{name} JSON 解析失败：{e}")
        return None


def valid_md(md: str, year: int = 2000) -> bool:
    try:
        m, d = (int(x) for x in md.split("-"))
        dt.date(year, m, d)
        return md == f"{m:02}-{d:02}"
    except Exception:  # noqa: BLE001
        return False


def main() -> int:
    # ---- L1 ----
    l1 = load("memorial-days.json")
    if l1:
        days = l1.get("days", [])
        check(l1.get("meta", {}).get("layer") == "L1", "L1 meta.layer 应为 L1")
        check(len(days) > 30, f"L1 条目过少：{len(days)}")
        seen: set[tuple[str, str]] = set()
        for x in days:
            md, name, kind = x.get("date"), x.get("name"), x.get("kind")
            check(valid_md(md or ""), f"L1 日期非法：{md} {name}")
            check(bool(name), "L1 存在无名条目")
            check(kind in {"节日", "国家级纪念日", "纪念日", "主题日"}, f"L1 kind 非法：{name}={kind}")
            check((md, name) not in seen, f"L1 重复条目：{md} {name}")
            seen.add((md, name))
        for md, name in NATIONAL_DAYS.items():
            check(any(x.get("date") == md and x.get("name") == name for x in days),
                  f"L1 缺少国家级纪念日：{name} ({md})")
        print(f"[L1] {len(days)} 条固定公历纪念日，四个国家级纪念日齐全")

    # ---- L2 + L3 规则 ----
    rules = load("rule-days.json")
    if rules:
        wr = rules.get("weekday_rules", [])
        for r in wr:
            check(1 <= r.get("month", 0) <= 12, f"规则月份非法：{r.get('name')}")
            check(0 <= r.get("weekday", -1) <= 6, f"规则星期非法：{r.get('name')}")
            check(1 <= r.get("nth", 0) <= 5, f"规则 nth 非法：{r.get('name')}")
        tr = rules.get("solar_term_rules", [])
        for r in tr:
            check(r.get("term") in JIEQI_ORDER, f"节气规则引用未知节气：{r.get('term')}")
        lf = rules.get("lunar_festivals", [])
        for f in lf:
            check(1 <= f.get("month", 0) <= 12, f"农历节日月份非法：{f.get('name')}")
            check(0 <= f.get("day", -1) <= 30, f"农历节日日非法：{f.get('name')}")
        print(f"[L2/L3] {len(wr)} 条星期规则、{len(tr)} 条节气规则、{len(lf)} 条农历节日规则")

    # ---- L3 基础表 ----
    table = load("lunar-table.json")
    if table:
        meta = table.get("meta", {})
        yr = meta.get("range", [])
        check(len(yr) == 2 and yr[0] <= yr[1], f"lunar-table.range 非法：{yr}")
        check(meta.get("jieqi_order") == JIEQI_ORDER, "meta.jieqi_order 与约定顺序不符")
        years = table.get("years", [])
        check([v["y"] for v in years] == list(range(yr[0], yr[1] + 1)), "年份序列不连续")
        leap_years = []
        for v in years:
            y, ms = v["y"], v["months"]
            check(len(ms) in (12, 13), f"{y} 年月数异常 {len(ms)}")
            if len(ms) == 13:
                leap_years.append(y)
            check(ms[0]["m"] == 1 and not ms[0]["leap"], f"{y} 首月不是正月")
            check(ms[-1]["m"] == 12 and not ms[-1]["leap"], f"{y} 末月不是腊月")
            check(len(v.get("jieqi", [])) == 24, f"{y} 节气数不为 24")
            check([j["name"] for j in v["jieqi"]] == JIEQI_ORDER, f"{y} 节气顺序异常")
            for j in v["jieqi"]:
                check(valid_md(j["date"], y), f"{y} 节气日期非法 {j['date']}")
            for i, m in enumerate(ms):
                check(m["days"] in (29, 30), f"{y} 月长异常 {m['days']}")
                try:
                    dt.date.fromisoformat(m["start"])
                except ValueError:
                    errors.append(f"{y} 月首日期非法：{m['start']}")
                if i > 0:
                    prev = dt.date.fromisoformat(ms[i - 1]["start"])
                    cur = dt.date.fromisoformat(m["start"])
                    check((cur - prev).days == ms[i - 1]["days"],
                          f"{y} 月首不连续：{ms[i - 1]['start']} -> {m['start']}")
        print(f"[L3] {len(years)} 年，闰月年份 {leap_years}")

    # ---- L4 ----
    hfiles = sorted(DATA.glob("holiday-*.json"))
    check(len(hfiles) >= 3, "L4 内置快照少于 3 个年份")
    for p in hfiles:
        h = load(p.name)
        if not h:
            continue
        year = int(p.stem.split("-")[1])
        check(h.get("year") == year, f"{p.name} 的 year 字段与文件名不符")
        check(bool(h.get("papers")), f"{p.name} 缺少国务院公告原文链接")
        days = h.get("days", [])
        check(bool(days), f"{p.name} days 为空")
        by_date: dict[str, set[bool]] = {}
        for x in days:
            ds = x.get("date", "")
            try:
                dd = dt.date.fromisoformat(ds)
            except ValueError:
                errors.append(f"{p.name} 日期非法：{ds}")
                continue
            check(dd.year == year, f"{p.name} 日期跨年：{ds}")
            check(isinstance(x.get("isOffDay"), bool), f"{p.name} isOffDay 非布尔：{ds}")
            check(bool(x.get("name")), f"{p.name} 条目缺 name：{ds}")
            by_date.setdefault(ds, set()).add(x.get("isOffDay"))
        conflicts = [k for k, v in by_date.items() if len(v) > 1]
        check(not conflicts, f"{p.name} 同一天同时标休与补班：{conflicts}")
        print(f"[L4] {year} 年 {len(days)} 条调休记录，公告 {len(h.get('papers', []))} 条")

    print("-" * 56)
    if errors:
        print(f"FAIL: {checks} 项校验中 {len(errors)} 项失败")
        for e in errors[:30]:
            print("  -", e)
        return 1
    print(f"PASS: {checks} 项校验全部通过")
    return 0


if __name__ == "__main__":
    sys.exit(main())
