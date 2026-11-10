//! 四层数据合并与对外查询接口。
//!
//! 合并优先级（详见 docs/数据规范.md）：
//!   补班日 > 法定休 > 周末 > 工作日
//! 标签顺序稳定为 L1 → L2 → L3 → L4，便于 UI 决定显示几条。

use crate::data;
use crate::date::Date;
use crate::json::{self, Value};
use crate::lunar::{LunarInfo, LunarTable};
use std::collections::BTreeMap;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Label {
    pub name: String,
    pub kind: String,
    pub layer: &'static str,
}

#[derive(Debug, Clone)]
pub struct DayInfo {
    pub date: Date,
    /// 0 = 周日 … 6 = 周六
    pub weekday: u32,
    pub workday: bool,
    pub rest: bool,
    pub labels: Vec<Label>,
    pub lunar: Option<LunarInfo>,
    pub jieqi: Option<String>,
    pub ganzhi: Option<String>,
    pub shengxiao: Option<String>,
    /// L4 命中的法定假名称（如「春节」），未命中为 None。
    pub holiday_name: Option<String>,
    /// 该日是否为调休补班（周末上班）。
    pub makeup: bool,
    /// 该日是否为某个法定假期的「节日正日」。放假区间内只此一天
    /// 可以显示节日名，其余日子只是假期，不能也叫这个节。
    pub festival_day: bool,
}

fn json_escape(s: &str) -> String {
    let mut out = String::with_capacity(s.len() + 8);
    for c in s.chars() {
        match c {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            '\n' => out.push_str("\\n"),
            '\r' => out.push_str("\\r"),
            '\t' => out.push_str("\\t"),
            c if (c as u32) < 0x20 => out.push_str(&format!("\\u{:04x}", c as u32)),
            c => out.push(c),
        }
    }
    out
}

fn json_opt_str(v: &Option<String>) -> String {
    match v {
        Some(s) => format!("\"{}\"", json_escape(s)),
        None => "null".to_string(),
    }
}

impl DayInfo {
    pub fn has_label(&self, name: &str) -> bool {
        self.labels.iter().any(|l| l.name == name)
    }
    pub fn label(&self, name: &str) -> Option<&Label> {
        self.labels.iter().find(|l| l.name == name)
    }

    /// 供上层界面消费的 JSON。核心不依赖任何序列化库。
    pub fn to_json(&self) -> String {
        let labels: Vec<String> = self
            .labels
            .iter()
            .map(|l| {
                format!(
                    "{{\"name\":\"{}\",\"kind\":\"{}\",\"layer\":\"{}\"}}",
                    json_escape(&l.name),
                    json_escape(&l.kind),
                    l.layer
                )
            })
            .collect();
        let lunar = match &self.lunar {
            Some(li) => format!(
                "{{\"month\":{},\"day\":{},\"leap\":{},\"month_days\":{},\"text\":\"{}\"}}",
                li.month,
                li.day,
                li.leap,
                li.month_days,
                json_escape(&li.text)
            ),
            None => "null".to_string(),
        };
        format!(
            concat!(
                "{{\"date\":\"{}\",\"weekday\":{},\"workday\":{},\"rest\":{},",
                "\"labels\":[{}],\"lunar\":{},\"jieqi\":{},\"ganzhi\":{},",
                "\"shengxiao\":{},\"holiday_name\":{},\"makeup\":{},",
                "\"festival_day\":{}}}"
            ),
            self.date.ymd(),
            self.weekday,
            self.workday,
            self.rest,
            labels.join(","),
            lunar,
            json_opt_str(&self.jieqi),
            json_opt_str(&self.ganzhi),
            json_opt_str(&self.shengxiao),
            json_opt_str(&self.holiday_name),
            self.makeup,
            self.festival_day
        )
    }
}

#[derive(Clone)]
struct Memorial {
    md: String,
    name: String,
    kind: String,
}
#[derive(Clone)]
struct WeekdayRule {
    name: String,
    month: u32,
    weekday: u32,
    nth: u32,
    kind: String,
}
#[derive(Clone)]
struct TermRule {
    name: String,
    term: String,
    kind: String,
}
#[derive(Clone)]
struct LunarFestival {
    name: String,
    month: u32,
    /// 0 表示该农历月最后一天（用于除夕）
    day: u32,
    kind: String,
}
#[derive(Clone)]
struct Holiday {
    date: Date,
    is_off: bool,
    name: String,
}

/// 假期名对应的「节日正日」判定规则。
#[derive(Clone)]
enum AnchorRule {
    /// 固定公历月日，如元旦 01-01、国庆节 10-01。
    Solar { month: u32, day: u32 },
    /// 农历月日（闰月不算），如春节正月初一、中秋八月十五。
    Lunar { month: u32, day: u32 },
    /// 节气当天，如清明节=清明。
    SolarTerm(String),
    /// 连休合并假期（如 2025 年上游写作「国庆节、中秋节」）。
    /// 子项必须是上表登记过的基础锚点，命中任意一个即为正日。
    Compound(Vec<String>),
}

#[derive(Clone)]
struct FestivalAnchor {
    name: String,
    rule: AnchorRule,
}

pub struct Calendar {
    l1: Vec<Memorial>,
    weekday_rules: Vec<WeekdayRule>,
    term_rules: Vec<TermRule>,
    lunar_festivals: Vec<LunarFestival>,
    lunar: LunarTable,
    holidays: BTreeMap<i32, Vec<Holiday>>,
    anchors: Vec<FestivalAnchor>,
}

fn req<'a>(v: &'a Value, key: &str, ctx: &str) -> Result<&'a Value, String> {
    v.get(key).ok_or_else(|| format!("{} 缺少字段 {}", ctx, key))
}
fn str_field(v: &Value, key: &str, ctx: &str) -> Result<String, String> {
    req(v, key, ctx)?
        .as_str()
        .map(|s| s.to_string())
        .ok_or_else(|| format!("{}.{} 非字符串", ctx, key))
}
fn int_field(v: &Value, key: &str, ctx: &str) -> Result<i64, String> {
    req(v, key, ctx)?
        .as_i64()
        .ok_or_else(|| format!("{}.{} 非整数", ctx, key))
}

impl Calendar {
    /// 用编译期内置数据构造，全程离线。
    pub fn try_builtin() -> Result<Self, String> {
        let mut cal = Calendar {
            l1: Vec::new(),
            weekday_rules: Vec::new(),
            term_rules: Vec::new(),
            lunar_festivals: Vec::new(),
            lunar: LunarTable::parse(data::LUNAR_TABLE)?,
            holidays: BTreeMap::new(),
            anchors: Vec::new(),
        };

        // L1
        let root = json::parse(data::MEMORIAL_DAYS)?;
        for d in req(&root, "days", "memorial-days")?
            .as_array()
            .ok_or("memorial-days.days 应为数组")?
        {
            let md = str_field(d, "date", "L1")?;
            Date::parse_md(&md, 2000)?; // 用闰年校验 MM-DD 合法性
            cal.l1.push(Memorial {
                md,
                name: str_field(d, "name", "L1")?,
                kind: str_field(d, "kind", "L1")?,
            });
        }

        // L2 + L3 节日规则
        let rules = json::parse(data::RULE_DAYS)?;
        for r in req(&rules, "weekday_rules", "rule-days")?
            .as_array()
            .ok_or("weekday_rules 应为数组")?
        {
            let month = int_field(r, "month", "weekday_rule")? as u32;
            let weekday = int_field(r, "weekday", "weekday_rule")? as u32;
            let nth = int_field(r, "nth", "weekday_rule")? as u32;
            if !(1..=12).contains(&month) || weekday > 6 || nth == 0 || nth > 5 {
                return Err(format!("规则型日期非法：month={} weekday={} nth={}", month, weekday, nth));
            }
            cal.weekday_rules.push(WeekdayRule {
                name: str_field(r, "name", "weekday_rule")?,
                month,
                weekday,
                nth,
                kind: str_field(r, "kind", "weekday_rule")?,
            });
        }
        for r in req(&rules, "solar_term_rules", "rule-days")?
            .as_array()
            .ok_or("solar_term_rules 应为数组")?
        {
            cal.term_rules.push(TermRule {
                name: str_field(r, "name", "solar_term_rule")?,
                term: str_field(r, "term", "solar_term_rule")?,
                kind: str_field(r, "kind", "solar_term_rule")?,
            });
        }
        for f in req(&rules, "lunar_festivals", "rule-days")?
            .as_array()
            .ok_or("lunar_festivals 应为数组")?
        {
            let month = int_field(f, "month", "lunar_festival")? as u32;
            let day = int_field(f, "day", "lunar_festival")? as u32;
            if !(1..=12).contains(&month) || day > 30 {
                return Err(format!("农历节日规则非法：month={} day={}", month, day));
            }
            cal.lunar_festivals.push(LunarFestival {
                name: str_field(f, "name", "lunar_festival")?,
                month,
                day,
                kind: str_field(f, "kind", "lunar_festival")?,
            });
        }

        // L4 假期名 → 节日正日（决定哪一天才可以显示节日名）
        let anchor_root = json::parse(data::FESTIVAL_ANCHORS)?;
        for a in req(&anchor_root, "anchors", "festival-anchors")?
            .as_array()
            .ok_or("festival-anchors.anchors 应为数组")?
        {
            let name = str_field(a, "name", "anchor")?;
            let typ = str_field(a, "type", "anchor")?;
            let rule = match typ.as_str() {
                "solar" | "lunar" => {
                    let month = int_field(a, "month", "anchor")? as u32;
                    let day = int_field(a, "day", "anchor")? as u32;
                    if !(1..=12).contains(&month) || !(1..=31).contains(&day) {
                        return Err(format!("节日正日日期非法：{} {}-{}", name, month, day));
                    }
                    if typ == "solar" {
                        AnchorRule::Solar { month, day }
                    } else {
                        AnchorRule::Lunar { month, day }
                    }
                }
                "solar_term" => AnchorRule::SolarTerm(str_field(a, "term", "anchor")?),
                "compound" => {
                    let raw = req(a, "parts", "anchor")?
                        .as_array()
                        .ok_or("compound.parts 应为数组")?;
                    let mut parts = Vec::new();
                    for item in raw {
                        parts.push(
                            item.as_str()
                                .map(|s| s.to_string())
                                .ok_or("compound.parts 含非字符串")?,
                        );
                    }
                    if parts.is_empty() {
                        return Err(format!("组合正日 {} 的 parts 为空", name));
                    }
                    AnchorRule::Compound(parts)
                }
                _ => return Err(format!("未知节日正日类型：{}", typ)),
            };
            cal.anchors.push(FestivalAnchor { name, rule });
        }
        // 组合正日的子项必须指向已登记的基础锚点，且不能自我嵌套。
        for a in &cal.anchors {
            if let AnchorRule::Compound(parts) = &a.rule {
                for p in parts {
                    let ok = cal
                        .anchors
                        .iter()
                        .any(|x| x.name == *p && !matches!(x.rule, AnchorRule::Compound(_)));
                    if !ok {
                        return Err(format!("组合正日 {} 的子项 {} 没有基础锚点", a.name, p));
                    }
                }
            }
        }

        // L4 内置快照
        for &(year, text) in data::BUILTIN_HOLIDAYS {
            cal.with_holiday_json(year, text)?;
        }
        Ok(cal)
    }

    pub fn builtin() -> Self {
        Self::try_builtin().expect("内置日历数据损坏")
    }

    /// 注入（或覆盖）某年的 L4 调休数据。校验失败时保留原有数据不变。
    pub fn with_holiday_json(&mut self, year: i32, text: &str) -> Result<(), String> {
        let root = json::parse(text)?;
        let declared = req(&root, "year", "holiday")?
            .as_i64()
            .ok_or("holiday.year 非整数")? as i32;
        if declared != year {
            return Err(format!("年份不匹配：请求 {} 数据声明 {}", year, declared));
        }
        let days = req(&root, "days", "holiday")?
            .as_array()
            .ok_or("holiday.days 应为数组")?;
        if days.is_empty() {
            return Err(format!("{} 年 days 为空，拒绝覆盖", year));
        }

        // 同一日期冲突时以「补班」优先，符合合并优先级第 1 条。
        let mut merged: BTreeMap<Date, Holiday> = BTreeMap::new();
        for d in days {
            let date = Date::parse(str_field(d, "date", "holiday.day")?.as_str())?;
            if date.year != year {
                return Err(format!("日期 {} 不属于 {} 年", date, year));
            }
            let is_off = req(d, "isOffDay", "holiday.day")?
                .as_bool()
                .ok_or("isOffDay 非布尔")?;
            let name = d.get_str("name").unwrap_or("").to_string();
            let h = Holiday { date, is_off, name };
            // 仅当「原有为休、新条目为补班」时覆盖，其余保留先出现的条目。
            let should_insert = match merged.get(&date) {
                None => true,
                Some(old) => old.is_off && !is_off,
            };
            if should_insert {
                merged.insert(date, h);
            }
        }
        self.holidays.insert(year, merged.into_values().collect());
        Ok(())
    }

    pub fn has_holiday_data(&self, year: i32) -> bool {
        self.holidays.contains_key(&year)
    }

    pub fn lunar_range(&self) -> (i32, i32) {
        self.lunar.range
    }

    /// 农历/干支数据的实际日期覆盖 [起, 止)，超出后 UI 应优雅降级。
    pub fn lunar_covered_range(&self) -> Option<(Date, Date)> {
        self.lunar.covered_range()
    }

    /// 上游 L4 的 `name` 在整个放假区间里重复出现（例如 10/1—10/7 都写
    /// 「国庆节」）。只有命中本表登记的「节日正日」时，界面才可以显示
    /// 这个节名；未登记的假期名一律不标，宁可少标也不把整段假期叫成节日。
    fn is_festival_day(
        &self,
        name: &str,
        date: Date,
        lunar: Option<&LunarInfo>,
        jieqi: Option<&str>,
    ) -> bool {
        self.matches_anchor(name, date, lunar, jieqi, 0)
    }

    fn matches_anchor(
        &self,
        name: &str,
        date: Date,
        lunar: Option<&LunarInfo>,
        jieqi: Option<&str>,
        depth: u32,
    ) -> bool {
        if depth > 2 {
            return false;
        }
        let Some(anchor) = self.anchors.iter().find(|a| a.name == name) else {
            return false;
        };
        match &anchor.rule {
            AnchorRule::Solar { month, day } => date.month == *month && date.day == *day,
            AnchorRule::Lunar { month, day } => lunar
                .map(|li| !li.leap && li.month == *month && li.day == *day)
                .unwrap_or(false),
            AnchorRule::SolarTerm(term) => jieqi == Some(term.as_str()),
            AnchorRule::Compound(parts) => parts
                .iter()
                .any(|p| self.matches_anchor(p, date, lunar, jieqi, depth + 1)),
        }
    }

    pub fn day(&self, date: Date) -> DayInfo {
        let mut labels: Vec<Label> = Vec::new();
        let md = date.md();

        // L1 固定公历纪念日
        for m in &self.l1 {
            if m.md == md {
                labels.push(Label { name: m.name.clone(), kind: m.kind.clone(), layer: "L1" });
            }
        }

        // L2 规则型（第 n 个星期几）
        for r in &self.weekday_rules {
            if r.month == date.month
                && Date::nth_weekday(date.year, r.month, r.weekday, r.nth) == Some(date)
            {
                labels.push(Label { name: r.name.clone(), kind: r.kind.clone(), layer: "L2" });
            }
        }

        // L2 节气型 + L3 基础数据
        let jieqi = self.lunar.jieqi_on(date);
        for r in &self.term_rules {
            if jieqi.as_deref() == Some(r.term.as_str()) {
                labels.push(Label { name: r.name.clone(), kind: r.kind.clone(), layer: "L2" });
            }
        }

        let (lunar, ganzhi, shengxiao) = match self.lunar.day_detail(date) {
            Some((info, g, s)) => (Some(info), Some(g), Some(s)),
            None => (None, None, None),
        };

        // L3 农历传统节日；闰月不触发
        if let Some(li) = &lunar {
            if !li.leap {
                for f in &self.lunar_festivals {
                    if f.month != li.month {
                        continue;
                    }
                    let hit = if f.day == 0 {
                        li.day == li.month_days
                    } else {
                        f.day == li.day
                    };
                    if hit {
                        labels.push(Label { name: f.name.clone(), kind: f.kind.clone(), layer: "L3" });
                    }
                }
            }
        }

        // L4 年度调休
        let mut has_off = false;
        let mut has_makeup = false;
        let mut holiday_name: Option<String> = None;
        if let Some(list) = self.holidays.get(&date.year) {
            for h in list.iter().filter(|h| h.date == date) {
                if h.is_off {
                    has_off = true;
                    if holiday_name.is_none() {
                        holiday_name = Some(h.name.clone());
                    }
                } else {
                    has_makeup = true;
                }
            }
        }

        // 放假区间里只有节日正日可以显示节名。其余日子照样是法定休
        // （颜色与「休」角标不变），但不能把 10/2 也叫「国庆节」。
        let festival_day = holiday_name
            .as_deref()
            .map(|name| self.is_festival_day(name, date, lunar.as_ref(), jieqi.as_deref()))
            .unwrap_or(false);

        // 优先级：补班 > 法定休 > 周末 > 工作日
        let mut workday = date.weekday() != 0 && date.weekday() != 6;
        if has_makeup {
            workday = true;
        } else if has_off {
            workday = false;
        }

        if has_makeup {
            labels.push(Label { name: "补班".into(), kind: "调休".into(), layer: "L4" });
        } else if festival_day {
            if let Some(name) = &holiday_name {
                // 上游名称可能比 L1/L3 简称更短（如「清明」vs「清明节」），
                // 同名或互为子串时都不重复出角标。
                let duplicate = labels.iter().any(|l| {
                    l.name == *name || l.name.contains(name.as_str()) || name.contains(l.name.as_str())
                });
                if !duplicate {
                    labels.push(Label { name: name.clone(), kind: "法定假".into(), layer: "L4" });
                }
            }
        }

        DayInfo {
            date,
            weekday: date.weekday(),
            workday,
            rest: !workday,
            labels,
            lunar,
            jieqi,
            ganzhi,
            shengxiao,
            holiday_name,
            makeup: has_makeup,
            festival_day,
        }
    }

    pub fn month(&self, year: i32, month: u32) -> Result<Vec<DayInfo>, String> {
        let first = Date::new(year, month, 1)?;
        let count = crate::date::days_in_month(year, month);
        Ok((0..count)
            .map(|i| self.day(first.add_days(i as i64)))
            .collect())
    }
}
