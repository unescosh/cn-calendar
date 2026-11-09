// 故意占用这个文件名：CI 里 `flutter create --platforms=... .` 若发现
// test/widget_test.dart 不存在，会生成引用模板 MyApp 的默认测试，导致 analyze 变红。
import 'package:flutter_test/flutter_test.dart';
import 'package:cn_calendar/day_info.dart';

void main() {
  test('DayInfo 能解析 cn_cal_cli 的输出', () {
    final DayInfo info = DayInfo.fromJson(<String, dynamic>{
      'date': '2026-09-30',
      'weekday': 3,
      'workday': true,
      'rest': false,
      'makeup': false,
      'labels': <Map<String, dynamic>>[
        <String, dynamic>{
          'name': '烈士纪念日',
          'kind': '国家级纪念日',
          'layer': 'L1',
        },
      ],
      'lunar': <String, dynamic>{
        'month': 8,
        'day': 20,
        'leap': false,
        'month_days': 29,
        'text': '八月二十',
      },
      'jieqi': null,
      'ganzhi': '丙午',
      'shengxiao': '马',
      'holiday_name': null,
    });

    expect(info.date.day, 30);
    expect(info.weekday, 3);
    expect(info.hasNationalMemorial, isTrue);
    expect(info.primaryText, '烈士纪念日');
    expect(info.lunar?.text, '八月二十');
    expect(info.badge, '');
  });

  test('补班日角标优先于休息日', () {
    final DayInfo info = DayInfo.fromJson(<String, dynamic>{
      'date': '2026-09-20',
      'weekday': 0,
      'workday': true,
      'rest': false,
      'makeup': true,
      'labels': <Map<String, dynamic>>[
        <String, dynamic>{
          'name': '补班',
          'kind': '调休',
          'layer': 'L4',
        },
      ],
      'lunar': null,
      'jieqi': null,
      'ganzhi': null,
      'shengxiao': null,
      'holiday_name': null,
    });
    expect(info.badge, '班');
    expect(info.workday, isTrue);
    expect(info.primaryText, '补班');
  });
}
