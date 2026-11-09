//! 过渡桥接：把 Rust 计算核心的结果以 JSON 输出给上层界面。
//! P2 会换成 FFI，但 JSON 契约保持不变（见 docs/数据规范.md）。
//!
//! 用法：
//!   cn_cal_cli day 2026-09-30
//!   cn_cal_cli month 2026 9
//!   cn_cal_cli range           输出农历表实际覆盖的公历日期范围

use cn_cal_core::{Calendar, Date};
use std::env;
use std::process;

fn fail(msg: &str) -> ! {
    eprintln!("cn_cal_cli: {}", msg);
    process::exit(1);
}

fn parse_i32(s: &str, what: &str) -> i32 {
    s.parse::<i32>()
        .unwrap_or_else(|_| fail(&format!("{} 不是合法整数：{}", what, s)))
}

/// 静默更新器把年度 JSON 写到 CN_CAL_HOLIDAY_DIR 指定的缓存目录，
/// 启动时按文件覆盖同名年份。校验失败的文件一律跳过并保留内置快照。
/// 这样「自动更新」才真正生效，而不是只下载了一个没人读的文件。
fn apply_cached_overrides(cal: &mut Calendar) {
    let Some(dir) = env::var_os("CN_CAL_HOLIDAY_DIR") else {
        return;
    };
    let Ok(entries) = std::fs::read_dir(dir) else {
        return;
    };
    for entry in entries.flatten() {
        let name = entry.file_name().to_string_lossy().into_owned();
        let Some(year) = name
            .strip_prefix("holiday-")
            .and_then(|s| s.strip_suffix(".json"))
            .and_then(|s| s.parse::<i32>().ok())
        else {
            continue;
        };
        if let Ok(text) = std::fs::read_to_string(entry.path()) {
            let _ = cal.with_holiday_json(year, &text);
        }
    }
}

fn main() {
    let args: Vec<String> = env::args().skip(1).collect();
    let mut cal = Calendar::try_builtin().unwrap_or_else(|e| fail(&format!("内置数据加载失败：{}", e)));
    apply_cached_overrides(&mut cal);

    if args.len() == 2 && args[0] == "day" {
        let date = Date::parse(&args[1]).unwrap_or_else(|e| fail(&e));
        println!("{}", cal.day(date).to_json());
    } else if args.len() == 3 && args[0] == "month" {
        let year = parse_i32(&args[1], "年份");
        let month = parse_i32(&args[2], "月份") as u32;
        let days = cal
            .month(year, month)
            .unwrap_or_else(|e| fail(&e));
        let items: Vec<String> = days.iter().map(|d| d.to_json()).collect();
        println!("[{}]", items.join(","));
    } else if args.len() >= 2 && args[0] == "verify" {
        match args[1].as_str() {
            "holiday" if args.len() == 4 => {
                let year = parse_i32(&args[2], "年份");
                let upstream = std::fs::read_to_string(&args[3])
                    .unwrap_or_else(|e| fail(&format!("读取上游数据失败：{}", e)));
                let builtin = cn_cal_core::data::BUILTIN_HOLIDAYS
                    .iter()
                    .find(|(y, _)| *y == year)
                    .map(|(_, text)| *text)
                    .unwrap_or_else(|| fail(&format!("{} 年无内置快照可比对", year)));
                match cn_cal_core::verify::compare_holiday(builtin, &upstream, year) {
                    Ok(report) => println!("{}", report.to_json()),
                    Err(e) => fail(&e),
                }
            }
            "weekday" => {
                let from = if args.len() > 2 { parse_i32(&args[2], "起始年") } else { 2020 };
                let to = if args.len() > 3 { parse_i32(&args[3], "结束年") } else { 2050 };
                match cn_cal_core::verify::verify_weekday(from, to) {
                    Ok(report) => println!("{}", report.to_json()),
                    Err(e) => fail(&e),
                }
            }
            _ => fail("用法: cn_cal_cli verify holiday <YYYY> <上游JSON路径> | verify weekday [起年] [止年]"),
        }
    } else if args.len() == 1 && args[0] == "range" {
        match cal.lunar_covered_range() {
            Some((from, until)) => println!(
                "{{\"from\":\"{}\",\"until\":\"{}\",\"years\":[{},{}]}}",
                from,
                until,
                cal.lunar_range().0,
                cal.lunar_range().1
            ),
            None => fail("农历表为空"),
        }
    } else {
        fail(concat!(
            "用法: cn_cal_cli day <YYYY-MM-DD> | month <YYYY> <M> | range | ",
            "verify weekday [起年] [止年] | verify holiday <YYYY> <上游JSON路径>"
        ));
    }
}
