import 'dart:convert';
import 'dart:io';

import 'resource_policy.dart';

/// 年度调休数据的静默更新器。
///
/// 契约（见 docs/数据规范.md、docs/资源占用规范.md）：
/// - 只拉 L4 年度 JSON，其余全部内置离线
/// - 多源依次尝试，任一成功即止
/// - 校验年份、日期、isOffDay 后才落盘
/// - 按发布季分频同步：11～1 月每天一轮，其余月份 30 天一轮，
///   避免每次启动都发网络请求（用户明确要求更新不要太频繁）
/// - 任何失败都静默跳过，绝不弹窗、绝不阻塞启动、绝不上报遥测
/// - 写入 CN_CAL_HOLIDAY_DIR，由 cn_cal_cli 启动时读取覆盖
/// - 返回是否真的写入了新文件，供界面清空月份缓存、避免显示过期调休
class UpdateService {
  const UpdateService(
    this.cacheDir, {
    this.policy = const ResourcePolicy(),
    this.now,
  });

  final Directory cacheDir;
  final ResourcePolicy policy;

  /// 可注入的时钟，仅供单元测试使用。
  final DateTime Function()? now;

  static const List<String> _sources = <String>[
    'https://cdn.jsdelivr.net/gh/NateScarlet/holiday-cn@master',
    'https://raw.githubusercontent.com/NateScarlet/holiday-cn/master',
  ];

  Future<bool> syncQuietly() async {
    final DateTime current = now == null ? DateTime.now() : now!();
    try {
      if (!await cacheDir.exists()) {
        await cacheDir.create(recursive: true);
      }
    } catch (_) {
      return false;
    }

    final File marker = File(
        '${cacheDir.path}${Platform.pathSeparator}${ResourcePolicy.syncMarkerName}');
    if (!policy.shouldRun(policy.readMarker(marker), current,
        policy.syncIntervalFor(current))) {
      return false;
    }

    final Set<int> years = <int>{current.year};
    // 国务院通常在 11 月发布次年安排，提前拉取
    if (current.month >= 11) {
      years.add(current.year + 1);
    }
    bool changed = false;
    for (final int year in years) {
      for (final String base in _sources) {
        if (await _tryFetch(base, year)) {
          changed = true;
          break;
        }
      }
    }
    // 失败也写标记：离线时若每次启动都重试，反而会反复触发 8 秒超时。
    policy.writeMarker(marker, current);
    return changed;
  }

  Future<bool> _tryFetch(String base, int year) async {
    HttpClient? client;
    try {
      client = HttpClient()..connectionTimeout = const Duration(seconds: 8);
      final HttpClientRequest request =
          await client.getUrl(Uri.parse('$base/$year.json'));
      final HttpClientResponse response = await request.close();
      if (response.statusCode != HttpStatus.ok) {
        return false;
      }
      final String body = await response.transform(utf8.decoder).join();
      if (!_validate(body, year)) {
        return false;
      }
      final File file = File(
          '${cacheDir.path}${Platform.pathSeparator}holiday-$year.json');
      await file.writeAsString(body, flush: true);
      return true;
    } catch (_) {
      return false;
    } finally {
      client?.close();
    }
  }

  bool _validate(String body, int year) {
    try {
      final dynamic decoded = jsonDecode(body);
      if (decoded is! Map<String, dynamic>) {
        return false;
      }
      if (decoded['year'] != year) {
        return false;
      }
      final dynamic days = decoded['days'];
      if (days is! List<dynamic> || days.isEmpty) {
        return false;
      }
      for (final dynamic item in days) {
        if (item is! Map<String, dynamic>) {
          return false;
        }
        final dynamic date = item['date'];
        if (date is! String || !date.startsWith('$year-')) {
          return false;
        }
        if (item['isOffDay'] is! bool) {
          return false;
        }
      }
      return true;
    } catch (_) {
      return false;
    }
  }
}
