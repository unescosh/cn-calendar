import 'dart:convert';
import 'dart:io';

import 'resource_policy.dart';
import 'update_service.dart';

class VerifySummary {
  const VerifySummary({
    required this.status,
    required this.checkedAt,
    required this.checks,
    required this.differences,
    this.dataChanged = false,
  });

  final String status;
  final DateTime checkedAt;
  final List<String> checks;
  final List<String> differences;

  /// 本轮是否写入了新的 L4 调休文件；为 true 时界面需清空月份缓存重新取数。
  final bool dataChanged;

  String get label {
    switch (status) {
      case 'consistent':
        return '数据核对一致';
      case 'differences':
        return '发现数据差异';
      default:
        return '离线 · 仅本地校验';
    }
  }
}

/// 启动时的静默核对，契约见 docs/数据核对规范.md、docs/资源占用规范.md。
///
/// 顺序：定期校准节流判断 → 同步 L4 上游数据到缓存 → 用 HTTP Date 头核对
/// 日期/星期基准 → 让 Rust 核心做星期连续性与快照差异比对 → 写报告。
/// 全程不 await 首屏；任何网络失败按 offline 处理，不弹窗、不阻塞。
/// 命中校准缓存时零网络请求、零 CLI 进程，直接复用上次报告，
/// 但 `differences` 状态仍会显示，差异不会被静默吞掉。
/// `run(force: true)` 是用户主动「立即校准」：跳过节流，走完整核对。
class VerifyService {
  const VerifyService({
    required this.cacheDir,
    required this.cliPath,
    this.policy = const ResourcePolicy(),
  });

  final Directory cacheDir;
  final String cliPath;
  final ResourcePolicy policy;

  static const List<String> _dateSources = <String>[
    'https://www.gov.cn/',
    'https://www.baidu.com/',
  ];

  Future<VerifySummary> run({bool force = false}) async {
    final DateTime now = DateTime.now().toUtc();
    final File reportFile = File(
        '${cacheDir.path}${Platform.pathSeparator}verify-report.json');
    if (!force) {
      final VerifySummary? cached = _cachedSummary(reportFile, now);
      if (cached != null) {
        return cached;
      }
    }

    final bool dataChanged = await UpdateService(cacheDir).syncQuietly();
    final List<Map<String, String>> checks = <Map<String, String>>[];
    final List<Map<String, String>> diffs = <Map<String, String>>[];
    bool online = false;

    // 1) 权威日期/星期基准：HTTP Date 响应头
    for (final String url in _dateSources) {
      final DateTime? remote = await _httpDate(url);
      if (remote == null) {
        continue;
      }
      online = true;
      final int remoteWd = remote.weekday % 7; // Dart: 1=Mon..7=Sun -> 0=Sun..6=Sat
      final int localWd = now.weekday % 7;
      if (remote.year != now.year ||
          remote.month != now.month ||
          remote.day != now.day) {
        diffs.add(<String, String>{
          'id': 'clock_skew',
          'detail': '本机 UTC 日期与 HTTP Date 头不符',
        });
      }
      final dynamic today = await _cliJson(<String>['day', _ymd(now)]);
      if (today is Map<String, dynamic> && today['weekday'] != remoteWd) {
        diffs.add(<String, String>{
          'id': 'weekday_mismatch',
          'detail': '本地算法星期 ${today['weekday']} 与权威基准 $remoteWd 不符',
        });
      }
      checks.add(<String, String>{
        'id': 'http-date-weekday',
        'status': diffs.isEmpty ? 'ok' : 'diff',
        'detail': 'Date 头 ${remote.toIso8601String()}，权威星期 $remoteWd，本机星期 $localWd',
      });
      break;
    }
    if (!online) {
      checks.add(<String, String>{
        'id': 'http-date-weekday',
        'status': 'skipped',
        'detail': '网络不可用，跳过在线基准',
      });
    }

    // 2) 本地公历/星期算法自洽（断网也跑，但每天最多一轮）
    final dynamic weekday = await _cliJson(<String>['verify', 'weekday']);
    if (weekday is Map<String, dynamic>) {
      final bool ok = weekday['consistent'] == true;
      if (!ok) {
        diffs.add(<String, String>{
          'id': 'weekday_mismatch',
          'detail': '星期连续性检查未通过',
        });
      }
      checks.add(<String, String>{
        'id': 'weekday-continuity',
        'status': ok ? 'ok' : 'diff',
        'detail': '${weekday['days']} 天往返与星期循环检查',
      });
    }

    // 3) L4 缓存与内置快照差异（缓存文件即上游原始数据）
    for (final FileSystemEntity entity in _holidayFiles()) {
      final String name = entity.path.split(Platform.pathSeparator).last;
      final String yearText = name.replaceAll('holiday-', '').replaceAll('.json', '');
      final int? year = int.tryParse(yearText);
      if (year == null) {
        continue;
      }
      final dynamic report =
          await _cliJson(<String>['verify', 'holiday', '$year', entity.path]);
      if (report is! Map<String, dynamic>) {
        continue;
      }
      final List<dynamic> items = report['differences'] as List<dynamic>? ?? <dynamic>[];
      for (final dynamic item in items) {
        if (item is Map<String, dynamic>) {
          diffs.add(<String, String>{
            'id': 'holiday_${item['kind']}',
            'detail': '$year 年 ${item['date']} 内置 ${item['builtin']} / 上游 ${item['upstream']}',
          });
        }
      }
      checks.add(<String, String>{
        'id': 'holiday-$year',
        'status': items.isEmpty ? 'ok' : 'diff',
        'detail': '内置 ${report['builtin_count']} 条 / 上游 ${report['upstream_count']} 条，差异 ${items.length} 处',
      });
    }

    final List<Map<String, String>> realDiffs = diffs;
    final String status = !online
        ? 'offline'
        : (realDiffs.isEmpty ? 'consistent' : 'differences');
    final Map<String, dynamic> report = <String, dynamic>{
      'checked_at': now.toIso8601String(),
      'mode': 'online-verify',
      'status': status,
      'sources': _dateSources,
      'checks': checks,
      'differences': realDiffs,
      'notes': <String>['本地 L1/L2/L3 未被联网数据改写', '仅 L4 调休写入缓存'],
    };
    try {
      await File('${cacheDir.path}${Platform.pathSeparator}verify-report.json')
          .writeAsString(jsonEncode(report), flush: true);
    } catch (_) {
      // 报告写不进去不影响日历本身
    }
    return VerifySummary(
      status: status,
      checkedAt: now,
      checks: checks
          .map((Map<String, String> c) => '[${c['status']}] ${c['id']}: ${c['detail']}')
          .toList(),
      differences: realDiffs
          .map((Map<String, String> d) => '${d['id']}: ${d['detail']}')
          .toList(),
      dataChanged: dataChanged,
    );
  }

  /// 校准间隔内且报告可解析 → 直接复用，零网络、零 CLI 进程。
  /// 跨年与系统时钟回拨不放行，必须重新核对。
  VerifySummary? _cachedSummary(File file, DateTime now) {
    try {
      if (!file.existsSync()) {
        return null;
      }
      final dynamic decoded = jsonDecode(file.readAsStringSync());
      if (decoded is! Map<String, dynamic>) {
        return null;
      }
      final DateTime? last =
          DateTime.tryParse(decoded['checked_at'] as String? ?? '');
      if (last == null) {
        return null;
      }
      final String status = decoded['status'] as String? ?? 'offline';
      // offline 报告用较短的重试间隔：联网恢复后尽快补一次权威日期核对。
      // 跨年（内置 L4 快照按年组织）或系统时钟回拨，一律强制重跑。
      if (policy.needsRecheck(last, now) ||
          policy.shouldRun(last, now, policy.intervalFor(status))) {
        return null;
      }
      final List<dynamic> checks =
          decoded['checks'] as List<dynamic>? ?? <dynamic>[];
      final List<dynamic> diffs =
          decoded['differences'] as List<dynamic>? ?? <dynamic>[];
      return VerifySummary(
        status: status,
        checkedAt: last,
        checks: checks
            .map((dynamic c) => c is Map<String, dynamic>
                ? '[${c['status']}] ${c['id']}: ${c['detail']}'
                : '$c')
            .toList(),
        differences: diffs
            .map((dynamic d) => d is Map<String, dynamic>
                ? '${d['id']}: ${d['detail']}'
                : '$d')
            .toList(),
      );
    } catch (_) {
      return null;
    }
  }

  List<FileSystemEntity> _holidayFiles() {
    try {
      return cacheDir
          .listSync()
          .where((FileSystemEntity e) =>
              e is File && e.path.split(Platform.pathSeparator).last.startsWith('holiday-'))
          .toList();
    } catch (_) {
      return <FileSystemEntity>[];
    }
  }

  Future<DateTime?> _httpDate(String url) async {
    HttpClient? client;
    try {
      client = HttpClient()..connectionTimeout = const Duration(seconds: 8);
      final HttpClientRequest request = await client.openUrl('HEAD', Uri.parse(url));
      final HttpClientResponse response = await request.close();
      final String? raw = response.headers.value('date');
      if (raw == null) {
        return null;
      }
      return HttpDate.parse(raw).toUtc();
    } catch (_) {
      return null;
    } finally {
      client?.close();
    }
  }

  Future<dynamic> _cliJson(List<String> args) async {
    try {
      final ProcessResult result = await Process.run(cliPath, args);
      if (result.exitCode != 0) {
        return null;
      }
      return jsonDecode(result.stdout as String);
    } catch (_) {
      return null;
    }
  }

  static String _ymd(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
}
