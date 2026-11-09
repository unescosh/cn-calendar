//! 农历与节气查询。数据来自 tools/gen_lunar_table.js 预生成的静态表，
//! 运行时不做天文计算，只做区间定位，保证跨平台结果一致。

use crate::date::Date;
use crate::json::{self, Value};

#[derive(Debug, Clone)]
pub struct LunarMonth {
    pub m: u32,
    pub leap: bool,
    pub days: u32,
    pub start: Date,
}

#[derive(Debug, Clone)]
pub struct LunarYear {
    pub y: i32,
    pub spring: Date,
    pub ganzhi: String,
    pub shengxiao: String,
    pub months: Vec<LunarMonth>,
    /// (节气名, MM-DD)，固定 24 条按节气顺序。
    pub jieqi: Vec<(String, String)>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct LunarInfo {
    pub month: u32,
    pub day: u32,
    pub leap: bool,
    /// 所在农历月的天数，用于「除夕」这类按月末定义的节日。
    pub month_days: u32,
    pub text: String,
}

const MONTH_NAMES: [&str; 12] = [
    "正月", "二月", "三月", "四月", "五月", "六月", "七月", "八月", "九月", "十月", "冬月", "腊月",
];
const SHORT_MONTH_NAMES: [&str; 12] = [
    "正", "二", "三", "四", "五", "六", "七", "八", "九", "十", "冬", "腊",
];
const DIGITS: [&str; 10] = ["一", "二", "三", "四", "五", "六", "七", "八", "九", "十"];

fn day_name(d: u32) -> String {
    match d {
        1..=10 => format!("初{}", DIGITS[(d - 1) as usize]),
        11..=19 => format!("十{}", DIGITS[(d - 11) as usize]),
        20 => "二十".to_string(),
        21..=29 => format!("廿{}", DIGITS[(d - 21) as usize]),
        30 => "三十".to_string(),
        _ => d.to_string(),
    }
}

pub fn lunar_text(month: u32, day: u32, leap: bool) -> String {
    if month == 0 || month > 12 {
        return String::new();
    }
    let month_name = if leap {
        format!("闰{}", SHORT_MONTH_NAMES[(month - 1) as usize])
    } else {
        MONTH_NAMES[(month - 1) as usize].to_string()
    };
    format!("{}{}", month_name, day_name(day))
}

#[derive(Debug, Clone)]
pub struct LunarTable {
    pub range: (i32, i32),
    pub years: Vec<LunarYear>,
}

fn req<'a>(v: &'a Value, key: &str, ctx: &str) -> Result<&'a Value, String> {
    v.get(key)
        .ok_or_else(|| format!("{} 缺少字段 {}", ctx, key))
}

impl LunarTable {
    pub fn parse(text: &str) -> Result<Self, String> {
        let root = json::parse(text)?;
        let meta = req(&root, "meta", "lunar-table")?;
        let range_arr = req(meta, "range", "lunar-table.meta")?
            .as_array()
            .ok_or("meta.range 应为数组")?;
        if range_arr.len() != 2 {
            return Err("meta.range 应为 [起始年, 结束年]".into());
        }
        let range = (
            range_arr[0].as_i64().ok_or("range[0] 非整数")? as i32,
            range_arr[1].as_i64().ok_or("range[1] 非整数")? as i32,
        );

        let year_values = req(&root, "years", "lunar-table")?
            .as_array()
            .ok_or("years 应为数组")?;
        let mut years = Vec::with_capacity(year_values.len());
        for yv in year_values {
            let ctx = "lunar-table.years[]";
            let y = req(yv, "y", ctx)?.as_i64().ok_or("y 非整数")? as i32;
            let spring = Date::parse(req(yv, "spring", ctx)?.as_str().ok_or("spring 非字符串")?)?;
            let ganzhi = req(yv, "ganzhi", ctx)?
                .as_str()
                .ok_or("ganzhi 非字符串")?
                .to_string();
            let shengxiao = req(yv, "shengxiao", ctx)?
                .as_str()
                .ok_or("shengxiao 非字符串")?
                .to_string();

            let mut months = Vec::new();
            for mv in req(yv, "months", ctx)?.as_array().ok_or("months 应为数组")? {
                let m = req(mv, "m", "month")?.as_i64().ok_or("m 非整数")? as u32;
                let leap = req(mv, "leap", "month")?.as_bool().ok_or("leap 非布尔")?;
                let days = req(mv, "days", "month")?.as_i64().ok_or("days 非整数")? as u32;
                let start = Date::parse(
                    req(mv, "start", "month")?
                        .as_str()
                        .ok_or("start 非字符串")?,
                )?;
                if !(1..=12).contains(&m) || !(29..=30).contains(&days) {
                    return Err(format!("{} 年农历月数据非法：m={} days={}", y, m, days));
                }
                months.push(LunarMonth { m, leap, days, start });
            }
            if months.is_empty() {
                return Err(format!("{} 年缺少农历月", y));
            }

            let mut jieqi = Vec::new();
            for jv in req(yv, "jieqi", ctx)?.as_array().ok_or("jieqi 应为数组")? {
                let name = req(jv, "name", "jieqi")?
                    .as_str()
                    .ok_or("jieqi.name 非字符串")?
                    .to_string();
                let md = req(jv, "date", "jieqi")?
                    .as_str()
                    .ok_or("jieqi.date 非字符串")?
                    .to_string();
                Date::parse_md(&md, y)?;
                jieqi.push((name, md));
            }
            if jieqi.len() != 24 {
                return Err(format!("{} 年节气数 {} != 24", y, jieqi.len()));
            }
            years.push(LunarYear { y, spring, ganzhi, shengxiao, months, jieqi });
        }
        if years.len() != (range.1 - range.0 + 1) as usize {
            return Err(format!(
                "年份数 {} 与 range {:?} 不符",
                years.len(),
                range
            ));
        }
        Ok(LunarTable { range, years })
    }

    /// 实际覆盖的公历日期范围 [起, 止)，由月首/月末决定。
    /// 注意：年份范围 2020-2050 不等于 2020-01-01 起，例如 2020 年春节在 1/25。
    pub fn covered_range(&self) -> Option<(Date, Date)> {
        let first = self.years.first()?;
        let last = self.years.last()?;
        let from = first.months[0].start;
        let tail = &last.months[last.months.len() - 1];
        let until = tail.start.add_days(tail.days as i64);
        Some((from, until))
    }

    pub fn in_range(&self, d: Date) -> bool {
        self.covered_range()
            .map(|(from, until)| d >= from && d < until)
            .unwrap_or(false)
    }

    /// 返回覆盖该公历日的农历年（按正月→次年正月划界）。
    pub fn year_for(&self, d: Date) -> Option<&LunarYear> {
        self.years.iter().find(|y| {
            let first = &y.months[0].start;
            let last = &y.months[y.months.len() - 1];
            let end = last.start.add_days(last.days as i64);
            d >= *first && d < end
        })
    }

    pub fn lookup(&self, d: Date) -> Option<LunarInfo> {
        let y = self.year_for(d)?;
        for m in &y.months {
            let end = m.start.add_days(m.days as i64);
            if d >= m.start && d < end {
                let day = (d.to_days() - m.start.to_days()) as u32 + 1;
                return Some(LunarInfo {
                    month: m.m,
                    day,
                    leap: m.leap,
                    month_days: m.days,
                    text: lunar_text(m.m, day, m.leap),
                });
            }
        }
        None
    }

    /// 节气按公历年归档，与农历年边界无关。
    pub fn jieqi_on(&self, d: Date) -> Option<String> {
        let rec = self.years.iter().find(|y| y.y == d.year)?;
        let md = d.md();
        rec.jieqi
            .iter()
            .find(|(_, date)| date == &md)
            .map(|(name, _)| name.clone())
    }

    pub fn day_detail(&self, d: Date) -> Option<(LunarInfo, String, String)> {
        let y = self.year_for(d)?;
        let info = self.lookup(d)?;
        Some((info, y.ganzhi.clone(), y.shengxiao.clone()))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn lunar_text_examples() {
        assert_eq!(lunar_text(1, 1, false), "正月初一");
        assert_eq!(lunar_text(8, 20, false), "八月二十");
        assert_eq!(lunar_text(11, 13, false), "冬月十三");
        assert_eq!(lunar_text(6, 1, true), "闰六初一");
        assert_eq!(lunar_text(12, 30, false), "腊月三十");
    }
}
