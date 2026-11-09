//! 离线核对：L4 快照差异比对 + 公历/星期算法自洽检查。
//! 联网由上层（Python 工具 / Dart VerifyService）负责，本模块只读本地数据。

use crate::date::{civil_from_days, Date};
use crate::json::{self, Value};
use std::collections::BTreeMap;

#[derive(Debug, Clone)]
pub struct HolidayDiff {
    pub date: String,
    pub kind: &'static str,
    pub builtin: Option<bool>,
    pub upstream: Option<bool>,
}

pub struct CompareReport {
    pub year: i32,
    pub builtin_count: usize,
    pub upstream_count: usize,
    pub differences: Vec<HolidayDiff>,
}

fn parse_days(text: &str, year: i32) -> Result<BTreeMap<String, bool>, String> {
    let root = json::parse(text)?;
    if root.get_i64("year") != Some(year as i64) {
        return Err(format!("数据声明年份与 {} 不符", year));
    }
    let days = root
        .get_array("days")
        .ok_or("缺少 days 数组")?
        .to_vec();
    if days.is_empty() {
        return Err("days 为空".into());
    }
    let mut map: BTreeMap<String, bool> = BTreeMap::new();
    for v in &days {
        let ds = v.get_str("date").ok_or("条目缺 date")?;
        let date = Date::parse(ds)?;
        if date.year != year {
            return Err(format!("日期 {} 不属于 {} 年", ds, year));
        }
        let off = v.get_bool("isOffDay").ok_or("isOffDay 非布尔")?;
        // 同日冲突时补班优先，与 Calendar 的合并规则一致
        let replace = match map.get(ds) {
            None => true,
            Some(&false) => false,
            Some(&true) => !off,
        };
        if replace {
            map.insert(ds.to_string(), off);
        }
    }
    Ok(map)
}

/// 比对内置快照与上游数据。纯函数，不修改任何状态。
pub fn compare_holiday(builtin: &str, upstream: &str, year: i32) -> Result<CompareReport, String> {
    let a = parse_days(builtin, year).map_err(|e| format!("内置快照：{}", e))?;
    let b = parse_days(upstream, year).map_err(|e| format!("上游数据：{}", e))?;
    let mut differences = Vec::new();
    for (date, &off_a) in &a {
        match b.get(date) {
            None => differences.push(HolidayDiff {
                date: date.clone(),
                kind: "missing",
                builtin: Some(off_a),
                upstream: None,
            }),
            Some(&off_b) if off_a != off_b => differences.push(HolidayDiff {
                date: date.clone(),
                kind: "changed",
                builtin: Some(off_a),
                upstream: Some(off_b),
            }),
            _ => {}
        }
    }
    for (date, &off_b) in &b {
        if !a.contains_key(date) {
            differences.push(HolidayDiff {
                date: date.clone(),
                kind: "added",
                builtin: None,
                upstream: Some(off_b),
            });
        }
    }
    Ok(CompareReport {
        year,
        builtin_count: a.len(),
        upstream_count: b.len(),
        differences,
    })
}

fn bool_json(v: Option<bool>) -> String {
    match v {
        Some(b) => b.to_string(),
        None => "null".to_string(),
    }
}

impl CompareReport {
    pub fn is_consistent(&self) -> bool {
        self.differences.is_empty()
    }
    pub fn to_json(&self) -> String {
        let diffs: Vec<String> = self
            .differences
            .iter()
            .map(|d| {
                format!(
                    "{{\"date\":\"{}\",\"kind\":\"{}\",\"builtin\":{},\"upstream\":{}}}",
                    d.date,
                    d.kind,
                    bool_json(d.builtin),
                    bool_json(d.upstream)
                )
            })
            .collect();
        format!(
            concat!(
                "{{\"year\":{},\"builtin_count\":{},\"upstream_count\":{},",
                "\"consistent\":{},\"differences\":[{}]}}"
            ),
            self.year,
            self.builtin_count,
            self.upstream_count,
            self.is_consistent(),
            diffs.join(",")
        )
    }
}

pub struct WeekdayReport {
    pub from: Date,
    pub until: Date,
    pub days: i64,
    pub mismatches: Vec<String>,
}

/// 逐日验证 civil 往返与星期连续性。断网也能跑，是"日期/星期必须准确"的离线兜底。
pub fn verify_weekday(from_year: i32, to_year: i32) -> Result<WeekdayReport, String> {
    let from = Date::new(from_year, 1, 1)?;
    let until = Date::new(to_year, 12, 31)?;
    if from > until {
        return Err("起始年晚于结束年".into());
    }
    let mut cur = from;
    let mut days: i64 = 0;
    let mut mismatches = Vec::new();
    let mut prev: Option<u32> = None;
    while cur <= until {
        let (y, m, d) = civil_from_days(cur.to_days());
        if (y, m, d) != (cur.year, cur.month, cur.day) {
            mismatches.push(format!("{} 公历往返不一致 -> {:04}-{:02}-{:02}", cur, y, m, d));
        }
        let wd = cur.weekday();
        if let Some(p) = prev {
            if wd != (p + 1) % 7 {
                mismatches.push(format!("{} 星期不连续 {} -> {}", cur, p, wd));
            }
        }
        prev = Some(wd);
        cur = cur.add_days(1);
        days += 1;
        if mismatches.len() > 20 {
            break;
        }
    }
    Ok(WeekdayReport { from, until, days, mismatches })
}

impl WeekdayReport {
    pub fn to_json(&self) -> String {
        let items: Vec<String> = self
            .mismatches
            .iter()
            .map(|s| format!("\"{}\"", s.replace('"', "'")))
            .collect();
        format!(
            concat!(
                "{{\"from\":\"{}\",\"until\":\"{}\",\"days\":{},",
                "\"consistent\":{},\"mismatches\":[{}]}}"
            ),
            self.from,
            self.until,
            self.days,
            self.mismatches.is_empty(),
            items.join(",")
        )
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn identical_data_is_consistent() {
        let text = r#"{"year":2026,"days":[{"name":"元旦","date":"2026-01-01","isOffDay":true}]}"#;
        let r = compare_holiday(text, text, 2026).unwrap();
        assert!(r.is_consistent());
    }
    #[test]
    fn detect_missing_added_changed() {
        let a = r#"{"year":2026,"days":[
            {"name":"元旦","date":"2026-01-01","isOffDay":true},
            {"name":"春节","date":"2026-02-17","isOffDay":true}]}"#;
        let b = r#"{"year":2026,"days":[
            {"name":"元旦","date":"2026-01-01","isOffDay":false},
            {"name":"国庆","date":"2026-10-01","isOffDay":true}]}"#;
        let r = compare_holiday(a, b, 2026).unwrap();
        assert_eq!(r.differences.len(), 3);
        assert!(r.differences.iter().any(|d| d.kind == "changed"));
        assert!(r.differences.iter().any(|d| d.kind == "missing"));
        assert!(r.differences.iter().any(|d| d.kind == "added"));
    }
    #[test]
    fn reject_wrong_year() {
        let a = r#"{"year":2026,"days":[{"name":"x","date":"2026-01-01","isOffDay":true}]}"#;
        let b = r#"{"year":2027,"days":[{"name":"x","date":"2027-01-01","isOffDay":true}]}"#;
        assert!(compare_holiday(a, b, 2026).is_err());
    }
    #[test]
    fn weekday_continuity_over_three_decades() {
        let r = verify_weekday(2020, 2050).unwrap();
        assert!(r.mismatches.is_empty());
        assert!(r.days > 11_000);
    }
}
