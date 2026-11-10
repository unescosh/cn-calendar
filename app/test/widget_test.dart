// 故意占用这个文件名：CI 里 `flutter create --platforms=... .` 若发现
// test/widget_test.dart 不存在，会生成引用模板 MyApp 的默认测试，导致 analyze 变红。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:cn_calendar/calendar_bridge.dart';
import 'package:cn_calendar/day_info.dart';
import 'package:cn_calendar/main.dart';
import 'package:cn_calendar/resource_policy.dart';

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

  group('DayInfo.dayKind：颜色分类优先级', () {
    DayInfo make({bool rest = false, bool makeup = false, String? holidayName}) {
      return DayInfo.fromJson(<String, dynamic>{
        'date': '2026-11-09',
        'weekday': 1,
        'workday': !rest && !makeup,
        'rest': rest,
        'makeup': makeup,
        'labels': <Map<String, dynamic>>[],
        'lunar': null,
        'jieqi': null,
        'ganzhi': null,
        'shengxiao': null,
        'holiday_name': holidayName,
      });
    }

    test('工作日 / 周末 / 法定假期 / 补班四类', () {
      expect(make().dayKind, DayKind.workday);
      expect(make(rest: true).dayKind, DayKind.weekend);
      expect(make(rest: true, holidayName: '中秋节').dayKind, DayKind.holiday);
      expect(make(makeup: true).dayKind, DayKind.makeup);
    });

    test('补班优先于法定假，法定假优先于周末', () {
      expect(make(rest: true, makeup: true, holidayName: '春节').dayKind,
          DayKind.makeup);
      expect(make(rest: true, holidayName: '春节').dayKind, DayKind.holiday);
    });
  });

  group('ResourcePolicy：定期校准节流', () {
    const ResourcePolicy policy = ResourcePolicy();
    final DateTime now = DateTime.utc(2026, 11, 9, 8);

    test('默认间隔：核对 7 天、平日同步 30 天、发布季 1 天、offline 6 小时', () {
      expect(policy.verifyInterval, const Duration(days: 7));
      expect(policy.syncIntervalQuiet, const Duration(days: 30));
      expect(policy.syncIntervalReleaseSeason, const Duration(days: 1));
      expect(policy.offlineRetryInterval, const Duration(hours: 6));
    });

    test('L4 同步按发布季分频', () {
      expect(policy.syncIntervalFor(DateTime.utc(2026, 11, 9)),
          const Duration(days: 1));
      expect(policy.syncIntervalFor(DateTime.utc(2026, 12, 9)),
          const Duration(days: 1));
      expect(policy.syncIntervalFor(DateTime.utc(2027, 1, 9)),
          const Duration(days: 1));
      expect(policy.syncIntervalFor(DateTime.utc(2026, 6, 9)),
          const Duration(days: 30));
      expect(policy.syncIntervalFor(DateTime.utc(2026, 10, 9)),
          const Duration(days: 30));
    });

    test('无记录、超过间隔、时钟回拨都要重跑', () {
      expect(policy.shouldRun(null, now, policy.verifyInterval), isTrue);
      expect(
          policy.shouldRun(now.subtract(const Duration(days: 6)), now,
              policy.verifyInterval),
          isFalse);
      expect(
          policy.shouldRun(now.subtract(const Duration(days: 7)), now,
              policy.verifyInterval),
          isTrue);
      // 系统时间被改回过去：不能一直沿用旧报告
      expect(
          policy.shouldRun(now.add(const Duration(hours: 1)), now,
              policy.verifyInterval),
          isTrue);
    });

    test('间隔可注入，边界按 >= 判定', () {
      const ResourcePolicy short = ResourcePolicy(
        verifyInterval: Duration(minutes: 10),
        syncIntervalQuiet: Duration(minutes: 10),
      );
      expect(
          short.shouldRun(now.subtract(const Duration(minutes: 9)), now,
              short.syncIntervalQuiet),
          isFalse);
      expect(
          short.shouldRun(now.subtract(const Duration(minutes: 10)), now,
              short.syncIntervalQuiet),
          isTrue);
    });

    test('offline 报告 6 小时重试，正常报告 7 天', () {
      const ResourcePolicy p = ResourcePolicy();
      expect(p.intervalFor('offline'), const Duration(hours: 6));
      expect(p.intervalFor('consistent'), const Duration(days: 7));
      expect(p.intervalFor('differences'), const Duration(days: 7));
      final DateTime last = now.subtract(const Duration(hours: 7));
      expect(p.shouldRun(last, now, p.intervalFor('offline')), isTrue);
      expect(p.shouldRun(last, now, p.intervalFor('consistent')), isFalse);
    });

    test('跨年 / 时钟回拨强制重跑，同年内不强制', () {
      const ResourcePolicy p = ResourcePolicy();
      expect(p.needsRecheck(null, now), isTrue);
      expect(p.needsRecheck(DateTime.utc(2025, 12, 31), now), isTrue);
      expect(p.needsRecheck(now.add(const Duration(hours: 1)), now), isTrue);
      expect(p.needsRecheck(now.subtract(const Duration(days: 3)), now),
          isFalse);
    });
  });

  group('ResourcePolicy：时间戳标记', () {
    const ResourcePolicy policy = ResourcePolicy();
    late Directory temp;
    late File marker;

    setUp(() {
      temp = Directory.systemTemp.createTempSync('cn_cal_policy_test');
      marker = File(
          '${temp.path}${Platform.pathSeparator}${ResourcePolicy.syncMarkerName}');
    });
    tearDown(() {
      if (temp.existsSync()) {
        temp.deleteSync(recursive: true);
      }
    });

    test('缺失或内容损坏都视为需要重跑', () {
      expect(policy.readMarker(marker), isNull);
      marker.writeAsStringSync('not-a-date');
      expect(policy.readMarker(marker), isNull);
    });

    test('写入后能读回，且按当月同步间隔命中节流', () {
      final DateTime now = DateTime.utc(2026, 6, 9, 8);
      policy.writeMarker(marker, now);
      final DateTime? last = policy.readMarker(marker);
      expect(last, isNotNull);
      expect(policy.syncIntervalFor(now), const Duration(days: 30));
      expect(policy.shouldRun(last, now, policy.syncIntervalFor(now)), isFalse);
      expect(
          policy.shouldRun(last, now.add(const Duration(days: 31)),
              policy.syncIntervalFor(now)),
          isTrue);
    });
  });

  group('MonthCache：月份结果复用', () {
    test('命中缓存直接返回同一份结果', () {
      final MonthCache<String> cache = MonthCache<String>(maxEntries: 3);
      expect(cache.get(2026, 11), isNull);
      cache.put(2026, 11, '十一月');
      expect(cache.get(2026, 11), '十一月');
      expect(cache.length, 1);
    });

    test('超出上限淘汰最早项，重复写同一月不占两个位置', () {
      final MonthCache<int> cache = MonthCache<int>(maxEntries: 2);
      cache.put(2026, 1, 1);
      cache.put(2026, 2, 2);
      cache.put(2026, 1, 10);
      cache.put(2026, 3, 3);
      expect(cache.length, 2);
      expect(cache.get(2026, 2), isNull);
      expect(cache.get(2026, 1), 10);
      expect(cache.get(2026, 3), 3);
    });

    test('L4 更新后 clear 清空全部月份', () {
      final MonthCache<int> cache = MonthCache<int>();
      cache.put(2026, 11, 11);
      cache.put(2026, 12, 12);
      cache.clear();
      expect(cache.length, 0);
      expect(cache.get(2026, 11), isNull);
    });
  });

  test('月份命中缓存时不启动 CLI 进程', () async {
    final MonthCache<List<DayInfo>> cache = MonthCache<List<DayInfo>>();
    final List<DayInfo> days = <DayInfo>[_sampleDay()];
    cache.put(2026, 11, days);
    // 故意给一个不存在的核心路径：若缓存没命中，Process.run 会直接抛异常。
    final CalendarBridge bridge = CalendarBridge(
      cliPath: '__cn_cal_cli_should_not_be_called__',
      cache: cache,
    );
    expect(await bridge.month(2026, 11), same(days));
    bridge.clearCache();
    expect(cache.length, 0);
  });

  group('节日正日、双主题与核心路径', () {
    test('festival_day 能解析，旧版核心缺字段时按 false', () {
      final Map<String, dynamic> base = <String, dynamic>{
        'date': '2026-10-02',
        'weekday': 5,
        'workday': false,
        'rest': true,
        'makeup': false,
        'labels': <Map<String, dynamic>>[],
        'lunar': null,
        'jieqi': null,
        'ganzhi': null,
        'shengxiao': null,
        'holiday_name': '国庆节',
      };
      final DayInfo modern = DayInfo.fromJson(<String, dynamic>{
        ...base,
        'festival_day': true,
        'labels': <Map<String, dynamic>>[
          <String, dynamic>{'name': '国庆节', 'kind': '节日', 'layer': 'L1'},
        ],
      });
      expect(modern.festivalDay, isTrue);
      expect(modern.hasFestivalLabel, isTrue);
      expect(modern.primaryText, '国庆节');

      final DayInfo legacy = DayInfo.fromJson(base);
      expect(legacy.festivalDay, isFalse);
      expect(legacy.hasFestivalLabel, isFalse);
      // 假期内非正日：没有节名标签，只剩节假日配色依据与「休」角标
      expect(legacy.dayKind, DayKind.holiday);
      expect(legacy.badge, '休');
    });

    test('黑色与白色两套配色的周末数字都改成橙红且互不相同', () {
      expect(CalendarPalette.dark.restNumber,
          isNot(CalendarPalette.light.restNumber));
      expect(CalendarPalette.dark.workdayNumber,
          isNot(CalendarPalette.dark.restNumber));
      expect(CalendarPalette.light.workdayNumber,
          isNot(CalendarPalette.light.restNumber));
      expect(CalendarPalette.dark.gridLine,
          isNot(CalendarPalette.light.gridLine));
    });

    test('子进程环境合并父进程环境，不会丢掉 PATH', () {
      final Map<String, String>? env =
          CalendarBridge.childEnvironment('C:/Temp/cn-cal-cache');
      expect(env, isNotNull);
      expect(env!['CN_CAL_HOLIDAY_DIR'], 'C:/Temp/cn-cal-cache');
      expect(env.length, greaterThan(1));
      expect(CalendarBridge.childEnvironment(null), isNull);
    });
  });
}

DayInfo _sampleDay() {
  return DayInfo.fromJson(<String, dynamic>{
    'date': '2026-11-09',
    'weekday': 1,
    'workday': true,
    'rest': false,
    'makeup': false,
    'labels': <Map<String, dynamic>>[],
    'lunar': null,
    'jieqi': null,
    'ganzhi': null,
    'shengxiao': null,
    'holiday_name': null,
  });
}
