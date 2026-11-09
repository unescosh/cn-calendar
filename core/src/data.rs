//! 内置静态数据。编译期嵌入二进制，运行时无需读文件、无需联网。

pub const MEMORIAL_DAYS: &str = include_str!("../../data/memorial-days.json");
pub const RULE_DAYS: &str = include_str!("../../data/rule-days.json");
pub const LUNAR_TABLE: &str = include_str!("../../data/lunar-table.json");

/// 内置 L4 年度调休快照（年份 -> 原始 JSON）。
/// 静默更新器拿到新数据后通过 Calendar::with_holiday_json 覆盖内存副本，
/// 不改写这里的编译期常量。
pub const BUILTIN_HOLIDAYS: &[(i32, &str)] = &[
    (2025, include_str!("../../data/holiday-2025.json")),
    (2026, include_str!("../../data/holiday-2026.json")),
    (2027, include_str!("../../data/holiday-2027.json")),
];
