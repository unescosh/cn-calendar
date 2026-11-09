import 'dart:convert';
import 'dart:io';

/// 年度调休数据的静默更新器。
///
/// 契约（见 docs/数据规范.md）：
/// - 只拉 L4 年度 JSON，其余全部内置离线
/// - 多源依次尝试，任一成功即止
/// - 校验年份、日期、isOffDay 后才落盘
/// - 任何失败都静默跳过，绝不弹窗、绝不阻塞启动、绝不上报遥测
/// - 写入 CN_CAL_HOLIDAY_DIR，由 cn_cal_cli 启动时读取覆盖
class UpdateService {
  const UpdateService(this.cacheDir);

  final Directory cacheDir;

  static const List<String> _sources = <String>[
    'https://cdn.jsdelivr.net/gh/NateScarlet/holiday-cn@master',
    'https://raw.githubusercontent.com/NateScarlet/holiday-cn/master',
  ];

  Future<void> syncQuietly() async {
    final DateTime now = DateTime.now();
    final Set<int> years = <int>{now.year};
    // 国务院通常在 11 月发布次年安排，提前拉取
    if (now.month >= 11) {
      years.add(now.year + 1);
    }
    try {
      if (!await cacheDir.exists()) {
        await cacheDir.create(recursive: true);
      }
    } catch (_) {
      return;
    }
    for (final int year in years) {
      for (final String base in _sources) {
        if (await _tryFetch(base, year)) {
          break;
        }
      }
    }
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
