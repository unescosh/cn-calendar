//! 集成测试：用独立算出的锚点锁死节日、农历、节气与调休合并逻辑。
//! 锚点由 tools/verify_data.py 与 Python datetime 独立核算，不复用被测实现推算。

use cn_cal_core::{data, Calendar, Date, DayInfo, LunarTable};
use std::sync::OnceLock;

static CAL: OnceLock<Calendar> = OnceLock::new();

fn cal() -> &'static Calendar {
    CAL.get_or_init(Calendar::builtin)
}
fn d(s: &str) -> Date {
    Date::parse(s).unwrap()
}
fn day(s: &str) -> DayInfo {
    cal().day(d(s))
}

#[test]
fn four_national_memorial_days() {
    for (date, name) in [
        ("2026-09-03", "中国人民抗日战争胜利纪念日"),
        ("2026-09-30", "烈士纪念日"),
        ("2026-12-04", "国家宪法日"),
        ("2026-12-13", "南京大屠杀死难者国家公祭日"),
    ] {
        let info = day(date);
        let label = info
            .label(name)
            .unwrap_or_else(|| panic!("{} 缺少 {}", date, name));
        assert_eq!(label.kind, "国家级纪念日", "{}", date);
        assert_eq!(label.layer, "L1", "{}", date);
    }
}

#[test]
fn fixed_days_hold_across_years() {
    for y in 2025..=2027 {
        assert!(
            day(&format!("{}-09-30", y)).has_label("烈士纪念日"),
            "{} 年应显示烈士纪念日",
            y
        );
        assert!(day(&format!("{}-10-01", y)).has_label("国庆节"));
    }
    assert!(day("2026-01-01").has_label("元旦"));
    assert!(day("2026-04-15").has_label("全民国家安全教育日"));
    assert!(day("2026-08-15").has_label("全国生态日"));
}

#[test]
fn l2_weekday_rules() {
    assert!(day("2026-05-17").has_label("全国助残日")); // 5 月第三个周日
    assert!(day("2026-06-13").has_label("文化和自然遗产日")); // 6 月第二个周六
    assert!(day("2026-09-19").has_label("全民国防教育日")); // 9 月第三个周六
    assert!(!day("2026-09-12").has_label("全民国防教育日"));
}

#[test]
fn l2_solar_term_rules() {
    assert_eq!(day("2026-04-05").jieqi.as_deref(), Some("清明"));
    assert!(day("2026-04-05").has_label("清明节"));
    assert_eq!(day("2026-09-23").jieqi.as_deref(), Some("秋分"));
    assert!(day("2026-09-23").has_label("中国农民丰收节"));
}

#[test]
fn l3_lunar_text_and_festivals() {
    let spring = day("2026-02-17");
    assert_eq!(spring.lunar.as_ref().unwrap().text, "正月初一");
    assert!(spring.has_label("春节"));
    assert_eq!(spring.ganzhi.as_deref(), Some("丙午"));
    assert_eq!(spring.shengxiao.as_deref(), Some("马"));

    assert_eq!(day("2025-01-29").lunar.as_ref().unwrap().text, "正月初一");
    assert_eq!(day("2025-01-29").ganzhi.as_deref(), Some("乙巳"));
    assert_eq!(day("2027-02-06").lunar.as_ref().unwrap().text, "正月初一");

    assert_eq!(day("2026-09-25").lunar.as_ref().unwrap().text, "八月十五");
    assert!(day("2026-09-25").has_label("中秋节"));
    assert!(day("2026-06-19").has_label("端午节"));

    // 2026 年腊月只有 29 天，除夕为腊月廿九
    let eve = day("2027-02-05");
    assert_eq!(eve.lunar.as_ref().unwrap().text, "腊月廿九");
    assert!(eve.has_label("除夕"));
    assert!(!day("2027-02-04").has_label("除夕"));
}

#[test]
fn leap_month_is_marked_and_triggers_no_festival() {
    let leap = day("2025-07-25"); // 闰六月初一
    let li = leap.lunar.as_ref().unwrap();
    assert!(li.leap);
    assert_eq!(li.month, 6);
    assert_eq!(li.text, "闰六初一");
    assert!(!leap.labels.iter().any(|l| l.layer == "L3"));
}

#[test]
fn special_2033_leap_winter_month() {
    let leap = day("2033-12-22");
    assert!(leap.lunar.as_ref().unwrap().leap);
    assert_eq!(leap.lunar.as_ref().unwrap().text, "闰冬初一");
    assert_eq!(day("2034-02-19").lunar.as_ref().unwrap().text, "正月初一");
}

#[test]
fn jieqi_lookup() {
    assert_eq!(day("2026-03-20").jieqi.as_deref(), Some("春分"));
    assert_eq!(day("2026-12-22").jieqi.as_deref(), Some("冬至"));
    assert!(day("2026-12-21").jieqi.is_none());
}

#[test]
fn l4_makeup_overrides_weekend() {
    // holiday-cn 2026 年补班日，均落在周末
    for date in ["2026-01-04", "2026-02-14", "2026-09-20", "2026-10-10"] {
        let info = day(date);
        assert!(info.makeup, "{} 应为补班", date);
        assert!(info.workday, "{} 补班应压过周末", date);
        assert!(!info.rest);
        assert!(info.has_label("补班"), "{} 缺少补班角标", date);
    }
}

#[test]
fn l4_holiday_overrides_workday() {
    for date in ["2026-01-01", "2026-02-17", "2026-10-01"] {
        let info = day(date);
        assert!(info.rest, "{} 应为休息日", date);
        assert!(!info.workday);
        assert!(info.holiday_name.is_some(), "{} 缺少法定假名称", date);
    }
}

#[test]
fn baseline_weekend_and_workday() {
    let mon = day("2026-11-09");
    assert_eq!(mon.weekday, 1);
    assert!(mon.workday && !mon.rest && !mon.makeup);
    let sat = day("2026-11-14");
    assert_eq!(sat.weekday, 6);
    assert!(sat.rest && !sat.workday);
}

#[test]
fn priority_makeup_beats_off_on_same_day() {
    let mut c = Calendar::builtin();
    let text = r#"{"year":2099,"days":[
        {"name":"测试放假","date":"2099-03-01","isOffDay":true},
        {"name":"调休","date":"2099-03-01","isOffDay":false}]}"#;
    c.with_holiday_json(2099, text).unwrap();
    let info = c.day(d("2099-03-01"));
    assert!(info.makeup);
    assert!(info.workday, "同日冲突时补班优先于法定休");
}

#[test]
fn labels_are_ordered_and_deduplicated() {
    let sep20 = day("2026-09-20");
    assert_eq!(sep20.labels[0].name, "公民道德宣传日");
    assert_eq!(sep20.labels[0].layer, "L1");
    assert_eq!(sep20.labels.last().unwrap().name, "补班");
    assert_eq!(sep20.labels.last().unwrap().layer, "L4");

    // L1「国庆节」与 L4 同名，只应出现一条
    let national = day("2026-10-01");
    assert_eq!(
        national.labels.iter().filter(|l| l.name.contains("国庆")).count(),
        1
    );
    // L2「清明节」与上游简称「清明」互为子串，也不应重复
    let qingming = day("2026-04-05");
    assert_eq!(
        qingming.labels.iter().filter(|l| l.name.contains("清明")).count(),
        1
    );
}

#[test]
fn out_of_range_graceful_degradation() {
    for date in ["2019-06-01", "2051-06-01"] {
        let info = day(date);
        assert!(info.lunar.is_none(), "{} 范围外不应有农历", date);
        assert!(info.ganzhi.is_none());
        assert!(info.jieqi.is_none());
    }
    // 降级不等于空白：固定公历纪念日仍要显示
    assert!(day("2051-06-01").has_label("国际儿童节"));
    assert!(day("2019-09-30").has_label("烈士纪念日"));
}

#[test]
fn builtin_holiday_snapshots() {
    for y in [2025, 2026, 2027] {
        assert!(cal().has_holiday_data(y), "{} 年内置快照缺失", y);
    }
    assert!(!cal().has_holiday_data(2024));
    assert_eq!(cal().lunar_range(), (2020, 2050));
}

#[test]
fn with_holiday_json_rejects_bad_data_without_mutating() {
    let mut c = Calendar::builtin();
    let before = c.day(d("2026-01-04"));
    let bad = [
        r#"{"year":2025,"days":[{"name":"x","date":"2025-01-01","isOffDay":true}]}"#,
        r#"{"year":2026,"days":[]}"#,
        r#"{"year":2026,"days":[{"name":"x","date":"2025-12-31","isOffDay":true}]}"#,
        r#"{"year":2026,"days":[{"name":"x","date":"2026-02-30","isOffDay":true}]}"#,
        r#"{"year":2026,"days":[{"name":"x","date":"2026-01-01"}]}"#,
        "not json at all",
    ];
    for text in bad {
        assert!(c.with_holiday_json(2026, text).is_err(), "应拒绝：{}", text);
    }
    let after = c.day(d("2026-01-04"));
    assert_eq!(before.workday, after.workday);
    assert_eq!(before.makeup, after.makeup);
}

#[test]
fn with_holiday_json_applies_valid_data() {
    let mut c = Calendar::builtin();
    let text = r#"{"year":2026,"papers":[],"days":[
        {"name":"自定义休","date":"2026-11-09","isOffDay":true},
        {"name":"调休","date":"2026-11-14","isOffDay":false}]}"#;
    c.with_holiday_json(2026, text).unwrap();
    assert!(c.day(d("2026-11-09")).rest);
    assert_eq!(c.day(d("2026-11-09")).holiday_name.as_deref(), Some("自定义休"));
    // 周六被补班覆盖为工作日
    assert!(c.day(d("2026-11-14")).workday);
    // 覆盖后原快照中该年的其它条目不再存在
    assert!(!c.day(d("2026-01-04")).makeup);
}

#[test]
fn month_grid_lengths() {
    assert_eq!(cal().month(2026, 2).unwrap().len(), 28);
    assert_eq!(cal().month(2024, 2).unwrap().len(), 29);
    let sep = cal().month(2026, 9).unwrap();
    assert_eq!(sep.len(), 30);
    assert_eq!(sep[0].date.ymd(), "2026-09-01");
    assert_eq!(sep[29].date.ymd(), "2026-09-30");
    assert!(cal().month(2026, 13).is_err());
}

#[test]
fn year_boundary() {
    let last = day("2026-12-31");
    let first = day("2027-01-01");
    assert_eq!(first.date, last.date.add_days(1));
    assert!(first.has_label("元旦"));
    assert!(first.rest);
    assert!(first.lunar.is_some());
}

#[test]
fn lunar_table_integrity() {
    let table = LunarTable::parse(data::LUNAR_TABLE).unwrap();
    assert_eq!(table.range, (2020, 2050));
    assert_eq!(table.years.len(), 31);
    for y in &table.years {
        assert!(y.months.len() == 12 || y.months.len() == 13, "{} 年月数", y.y);
        assert_eq!(y.jieqi.len(), 24, "{} 年节气数", y.y);
        assert_eq!(y.months[0].m, 1);
        assert_eq!(y.months.last().unwrap().m, 12);
        for m in &y.months {
            assert!(m.days == 29 || m.days == 30);
        }
    }
    let (from, until) = cal().lunar_covered_range().unwrap();
    assert_eq!(from.ymd(), "2020-01-25");
    assert!(until > d("2051-01-01") && until < d("2051-03-01"));
}

/// 遍历 2020-01-25 ～ 2050 年腊月末的每一天：
/// 农历日连续、闰月不触发传统节日、标签层序稳定。
/// 这比若干硬编码锚点更能抓出月表错位。
#[test]
fn full_range_lunar_continuity_and_invariants() {
    let (from, until) = cal().lunar_covered_range().unwrap();
    let mut cur = from;
    let mut prev: Option<cn_cal_core::LunarInfo> = None;
    let mut days = 0i64;
    while cur < until {
        let info = cal().day(cur);
        let li = info
            .lunar
            .as_ref()
            .unwrap_or_else(|| panic!("{} 在覆盖范围内却无农历", cur));
        assert!(li.day >= 1 && li.day <= li.month_days, "{} 农历日越界", cur);
        if let Some(p) = &prev {
            let expected = if p.day == p.month_days { 1 } else { p.day + 1 };
            assert_eq!(li.day, expected, "{} 农历日不连续：{:?} -> {:?}", cur, p, li);
        }
        if li.leap {
            assert!(
                !info.labels.iter().any(|l| l.layer == "L3"),
                "{} 闰月不应触发传统节日",
                cur
            );
        }
        let layers: Vec<&str> = info.labels.iter().map(|l| l.layer).collect();
        let mut sorted = layers.clone();
        sorted.sort();
        assert_eq!(layers, sorted, "{} 标签层序不稳定", cur);
        prev = Some(li.clone());
        cur = cur.add_days(1);
        days += 1;
    }
    assert!(days > 11_000, "覆盖范围天数异常：{}", days);
}

/// 上游 holiday-cn 把整个放假区间都写上同一个节名，
/// 核心必须只在「节日正日」保留节名标签，其余日子只留休/班与配色。
#[test]
fn festival_name_only_on_anchor_day() {
    for date in ["2026-10-01", "2026-10-02", "2026-10-07"] {
        let info = day(date);
        assert!(info.rest, "{} 应处于国庆假期", date);
        assert_eq!(info.holiday_name.as_deref(), Some("国庆节"), "{}", date);
    }
    assert!(day("2026-10-01").festival_day, "10/1 是国庆节正日");
    assert!(day("2026-10-01").has_label("国庆节"));
    for date in ["2026-10-02", "2026-10-03", "2026-10-07"] {
        let info = day(date);
        assert!(!info.festival_day, "{} 不该是节日正日", date);
        assert!(
            !info.labels.iter().any(|l| l.name == "国庆节"),
            "{} 不能把假期里每一天都叫国庆节",
            date
        );
    }
    assert!(day("2026-09-25").has_label("中秋节"), "中秋正日应有节名");
    assert!(
        !day("2026-09-26").labels.iter().any(|l| l.name == "中秋节"),
        "中秋假期第二天不能再叫中秋节"
    );
}

/// 2025 年国庆与中秋连休，上游写作「国庆节、中秋节」，
/// 两个正日（10/1 国庆、10/6 中秋）都要保住自己的节名。
#[test]
fn compound_holiday_has_two_anchor_days() {
    assert_eq!(
        day("2025-10-01").holiday_name.as_deref(),
        Some("国庆节、中秋节")
    );
    assert!(day("2025-10-01").festival_day);
    assert!(day("2025-10-01").has_label("国庆节"));
    assert!(day("2025-10-06").festival_day);
    assert!(day("2025-10-06").has_label("中秋节"));
    assert!(!day("2025-10-03").festival_day);
    assert!(day("2025-10-03").labels.is_empty());
}

#[test]
fn traditional_festivals_are_present() {
    for (date, name) in [
        ("2026-02-21", "破五"),
        ("2026-03-20", "龙抬头"),
        ("2026-11-09", "寒衣节"),
        ("2026-11-23", "下元节"),
        ("2026-12-22", "冬至节"),
    ] {
        assert!(day(date).has_label(name), "{} 缺少传统节日 {}", date, name);
    }
    // 闰月里的同名农历日不触发传统节日（既有口径不能被新节日破坏）
    assert!(!day("2025-07-25").labels.iter().any(|l| l.layer == "L3"));
}
