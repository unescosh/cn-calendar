/// DayInfo 的 Dart 映射，字段与 docs/数据规范.md 及 cn_cal_cli 输出严格一致。
/// 这里只做反序列化与展示派生，不做任何日期计算——计算全在 Rust 核心。

/// 界面配色分类。口径：补班 > 法定假期 > 周末 > 工作日，
/// 与核心「补班日 > 法定休 > 周末 > 工作日」的合并优先级一致。
/// 只用于显示，不参与任何日期计算。
enum DayKind { workday, weekend, holiday, makeup }

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
    this.festivalDay = false,
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
  /// 是否法定假期的「节日正日」。放假区间内只有这一天能显示节名。
  final bool festivalDay;

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
      // 旧版核心没有这个字段，缺省按 false 处理，保证前后兼容。
      festivalDay: json['festival_day'] as bool? ?? false,
    );
  }

  bool get hasNationalMemorial =>
      labels.any((CalendarLabel l) => l.isNationalMemorial);

  /// 格子里显示的是节日/纪念日名称（需要加粗），而不是农历日或节气。
  bool get hasFestivalLabel => labels.isNotEmpty;

  /// 格子里最多露两个标签，节日 / 国家级纪念日优先于主题日。
  /// UOS 第 6 步实机反馈：11/9 的「寒衣节」原先被同日 L1
  /// 「全国消防日」整个挤进详情弹窗，数据没丢但月历上看不到。
  /// 没有标签时退回节气、农历日。
  String get primaryText {
    if (labels.isNotEmpty) {
      final List<CalendarLabel> sorted = List<CalendarLabel>.of(labels)
        ..sort((CalendarLabel a, CalendarLabel b) =>
            _labelPriority(a).compareTo(_labelPriority(b)));
      return sorted.take(2).map((CalendarLabel l) => l.name).join('\n');
    }
    if (jieqi != null) {
      return jieqi!;
    }
    return lunar?.text ?? '';
  }

  static int _labelPriority(CalendarLabel l) {
    switch (l.kind) {
      case '节日':
      case '国家级纪念日':
        return 0;
      case '法定假':
      case '调休':
        return 1;
      case '纪念日':
        return 2;
      default:
        return 3; // 主题日等
    }
  }

  /// 休 / 班角标；普通工作日不显示。
  String get badge {
    if (makeup) {
      return '班';
    }
    return rest ? '休' : '';
  }

  /// 颜色分类：法定假期以核心给出的 L4 假名判定，普通周末按 rest 判定，
  /// 补班日优先（周末上班要单独标出来）。国家级纪念日由界面另行压色。
  DayKind get dayKind {
    if (makeup) {
      return DayKind.makeup;
    }
    if (holidayName != null) {
      return DayKind.holiday;
    }
    if (rest) {
      return DayKind.weekend;
    }
    return DayKind.workday;
  }
}
