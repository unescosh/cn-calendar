//! 公历日期工具。基于 Howard Hinnant 的 civil calendar 算法，
//! 以 1970-01-01 为第 0 天，支持负偏移，不依赖系统时区或 libc。

use std::fmt;

#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub struct Date {
    pub year: i32,
    pub month: u32,
    pub day: u32,
}

impl fmt::Display for Date {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{:04}-{:02}-{:02}", self.year, self.month, self.day)
    }
}

pub fn is_leap_year(y: i32) -> bool {
    (y % 4 == 0 && y % 100 != 0) || y % 400 == 0
}

pub fn days_in_month(y: i32, m: u32) -> u32 {
    match m {
        1 | 3 | 5 | 7 | 8 | 10 | 12 => 31,
        4 | 6 | 9 | 11 => 30,
        2 if is_leap_year(y) => 29,
        2 => 28,
        _ => 0,
    }
}

pub fn days_from_civil(y: i32, m: u32, d: u32) -> i64 {
    let y = y as i64 - if m <= 2 { 1 } else { 0 };
    let era = (if y >= 0 { y } else { y - 399 }) / 400;
    let yoe = y - era * 400;
    let mp = m as i64 + if m > 2 { -3 } else { 9 };
    let doy = (153 * mp + 2) / 5 + d as i64 - 1;
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    era * 146097 + doe - 719468
}

pub fn civil_from_days(z: i64) -> (i32, u32, u32) {
    let z = z + 719468;
    let era = (if z >= 0 { z } else { z - 146096 }) / 146097;
    let doe = z - era * 146097;
    let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365;
    let y = yoe + era * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = doy - (153 * mp + 2) / 5 + 1;
    let m = mp + if mp < 10 { 3 } else { -9 };
    (
        (y + if m <= 2 { 1 } else { 0 }) as i32,
        m as u32,
        d as u32,
    )
}

impl Date {
    pub fn new(year: i32, month: u32, day: u32) -> Result<Self, String> {
        if !(1..=12).contains(&month) {
            return Err(format!("月份非法：{}", month));
        }
        if day < 1 || day > days_in_month(year, month) {
            return Err(format!("日期非法：{:04}-{:02}-{:02}", year, month, day));
        }
        Ok(Date { year, month, day })
    }

    pub fn parse(s: &str) -> Result<Self, String> {
        let parts: Vec<&str> = s.trim().split('-').collect();
        if parts.len() != 3 {
            return Err(format!("日期格式应为 YYYY-MM-DD：{}", s));
        }
        let y: i32 = parts[0]
            .parse()
            .map_err(|_| format!("年份非法：{}", s))?;
        let m: u32 = parts[1]
            .parse()
            .map_err(|_| format!("月份非法：{}", s))?;
        let d: u32 = parts[2]
            .parse()
            .map_err(|_| format!("日非法：{}", s))?;
        Date::new(y, m, d)
    }

    /// 解析 MM-DD 形式，套用到指定年份（用于 L1 固定纪念日与节气表）。
    pub fn parse_md(md: &str, year: i32) -> Result<Self, String> {
        let parts: Vec<&str> = md.trim().split('-').collect();
        if parts.len() != 2 {
            return Err(format!("格式应为 MM-DD：{}", md));
        }
        let m: u32 = parts[0]
            .parse()
            .map_err(|_| format!("月份非法：{}", md))?;
        let d: u32 = parts[1]
            .parse()
            .map_err(|_| format!("日非法：{}", md))?;
        Date::new(year, m, d)
    }

    pub fn to_days(self) -> i64 {
        days_from_civil(self.year, self.month, self.day)
    }

    pub fn from_days(z: i64) -> Self {
        let (y, m, d) = civil_from_days(z);
        Date { year: y, month: m, day: d }
    }

    pub fn add_days(self, n: i64) -> Self {
        Date::from_days(self.to_days() + n)
    }

    /// 0 = 周日，1 = 周一 … 6 = 周六。
    pub fn weekday(self) -> u32 {
        (self.to_days() + 4).rem_euclid(7) as u32
    }

    pub fn md(self) -> String {
        format!("{:02}-{:02}", self.month, self.day)
    }

    pub fn ymd(self) -> String {
        self.to_string()
    }

    /// 该月第 n 个指定星期几的日期（n 从 1 开始）；不存在则返回 None。
    pub fn nth_weekday(year: i32, month: u32, weekday: u32, nth: u32) -> Option<Date> {
        if nth == 0 || weekday > 6 {
            return None;
        }
        let first = Date::new(year, month, 1).ok()?;
        let delta = (weekday as i64 - first.weekday() as i64).rem_euclid(7);
        let day = 1 + delta + (nth as i64 - 1) * 7;
        if day > days_in_month(year, month) as i64 {
            return None;
        }
        Date::new(year, month, day as u32).ok()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn civil_roundtrip() {
        for z in [-719528i64, -1000, -1, 0, 1, 19723, 20000, 100000] {
            let (y, m, d) = civil_from_days(z);
            assert_eq!(days_from_civil(y, m, d), z, "z={}", z);
        }
    }

    #[test]
    fn known_weekdays() {
        assert_eq!(Date::new(1970, 1, 1).unwrap().weekday(), 4);
        assert_eq!(Date::new(2026, 9, 30).unwrap().weekday(), 3);
        assert_eq!(Date::new(2026, 11, 9).unwrap().weekday(), 1);
        assert_eq!(Date::new(2000, 1, 1).unwrap().weekday(), 6);
    }

    #[test]
    fn leap_and_bounds() {
        assert!(Date::new(2024, 2, 29).is_ok());
        assert!(Date::new(2023, 2, 29).is_err());
        assert!(Date::new(2026, 13, 1).is_err());
        assert_eq!(Date::new(2026, 12, 31).unwrap().add_days(1).ymd(), "2027-01-01");
    }

    #[test]
    fn nth_weekday_examples() {
        // 2026 年 9 月第三个星期六 = 全民国防教育日
        assert_eq!(Date::nth_weekday(2026, 9, 6, 3).unwrap().ymd(), "2026-09-19");
        // 2026 年 5 月第三个星期日 = 全国助残日
        assert_eq!(Date::nth_weekday(2026, 5, 0, 3).unwrap().ymd(), "2026-05-17");
        assert_eq!(Date::nth_weekday(2026, 2, 1, 5), None);
    }
}
