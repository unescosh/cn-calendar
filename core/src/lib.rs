//! cn_cal_core — 中国桌面日历计算核心
//!
//! 设计约束：
//! - 零外部依赖，纯 `std`，可离线编译与交叉编译
//! - 全部节日数据编译期内置；仅 L4 年度调休支持运行时注入
//! - 不含任何账号、网络、会员、广告、备忘录相关模块
//!
//! 快速使用：
//! ```
//! use cn_cal_core::{Calendar, Date};
//! let cal = Calendar::try_builtin().unwrap();
//! let d = cal.day(Date::parse("2026-09-30").unwrap());
//! assert!(d.has_label("烈士纪念日"));
//! ```

pub mod calendar;
pub mod data;
pub mod date;
pub mod json;
pub mod lunar;
pub mod verify;

pub use calendar::{Calendar, DayInfo, Label};
pub use date::{civil_from_days, days_from_civil, days_in_month, is_leap_year, Date};
pub use lunar::{lunar_text, LunarInfo, LunarTable, LunarYear};

pub const VERSION: &str = env!("CARGO_PKG_VERSION");
