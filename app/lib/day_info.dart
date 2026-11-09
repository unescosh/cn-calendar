/// DayInfo 的 Dart 映射，字段与 docs/数据规范.md 及 cn_cal_cli 输出严格一致。
/// 这里只做反序列化与展示派生，不做任何日期计算——计算全在 Rust 核心。

class CalendarLabel {
  const CalendarLabel({
    required this.name,
    required this.kind,
    required this.layer,
  });

  final String name;
  final String kind;
  final String layer;

  factory CalendarLabel.fromJson(Map<String, dynamic> json) => CalendarLabel(
        name: json['name'] as String,
        kind: json['kind'] as String,
        layer: json['layer'] as String,
      );

  bool get isNationalMemorial => kind == '国家级纪念日';
}

class LunarDay {
  const LunarDay({
    required this.month,
    required this.day,
    required this.leap,
    required this.monthDays,
    required this.text,
  });

  final int month;
  final int day;
  final bool leap;
  final int monthDays;
  final String text;

  factory LunarDay.fromJson(Map<String, dynamic> json) => LunarDay(
        month: json['month'] as int,
        day: json['day'] as int,
        leap: json['leap'] as bool,
        monthDays: json['month_days'] as int,
        text: json['text'] as String,
      );
}

class DayInfo {
  const DayInfo({
    required this.date,
    required this.weekday,
    required this.workday,
    required this.rest,
    required this.makeup,
    required this.labels,
    required this.lunar,
    required this.jieqi,
    required this.ganzhi,
    required this.shengxiao,
    required this.holidayName,
  });

  final DateTime date;
  /// 0 = 周日 … 6 = 周六（与核心一致，注意不同于 DateTime.weekday）
  final int weekday;
  final bool workday;
  final bool rest;
  final bool makeup;
  final List<CalendarLabel> labels;
  final LunarDay? lunar;
  final String? jieqi;
  final String? ganzhi;
  final String? shengxiao;
  final String? holidayName;

  factory DayInfo.fromJson(Map<String, dynamic> json) {
    final rawLabels = json['labels'] as List<dynamic>? ?? <dynamic>[];
    final rawLunar = json['lunar'];
    return DayInfo(
      date: DateTime.parse(json['date'] as String),
      weekday: json['weekday'] as int,
      workday: json['workday'] as bool,
      rest: json['rest'] as bool,
      makeup: json['makeup'] as bool,
      labels: rawLabels
          .map((dynamic e) =>
              CalendarLabel.fromJson(e as Map<String, dynamic>))
          .toList(),
      lunar: rawLunar == null
          ? null
          : LunarDay.fromJson(rawLunar as Map<String, dynamic>),
      jieqi: json['jieqi'] as String?,
      ganzhi: json['ganzhi'] as String?,
      shengxiao: json['shengxiao'] as String?,
      holidayName: json['holiday_name'] as String?,
    );
  }

  bool get hasNationalMemorial =>
      labels.any((CalendarLabel l) => l.isNationalMemorial);

  /// 格子里优先显示节日名，其次节气，最后农历日。
  String get primaryText {
    if (labels.isNotEmpty) {
      return labels.first.name;
    }
    if (jieqi != null) {
      return jieqi!;
    }
    return lunar?.text ?? '';
  }

  /// 休 / 班角标；普通工作日不显示。
  String get badge {
    if (makeup) {
      return '班';
    }
    return rest ? '休' : '';
  }
}
