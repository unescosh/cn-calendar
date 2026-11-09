import 'dart:io';

/// 轻量运行策略。契约与量化口径见 docs/资源占用规范.md、docs/数据核对规范.md。
///
/// 用户 2026-11-09 明确：节假日与纪念日大多是固定或提前定好的，
/// 常驻后台的软件不需要频繁联网，「定期校准」即可，但精确性不能降。
/// 因此分三层：
/// - 本地计算：每次启动照常执行，零网络、零额外进程，精确性不依赖联网。
/// - 联网权威核对：默认每 7 天一轮；跨年 / 时钟回拨 / 用户点「立即校准」强制重跑。
/// - L4 年度调休：国务院一年发布一次，11～1 月每天查公告，其余月份 30 天查一次。
///
/// 三条资源约束：
/// 1. 常驻空闲时不做周期轮询、不做动画、不主动唤醒 CPU。
/// 2. 命中缓存时零网络请求、零 CLI 进程。
/// 3. 已加载过的月份不重复启动 CLI 进程。
class ResourcePolicy {
  const ResourcePolicy({
    this.verifyInterval = const Duration(days: 7),
    this.syncIntervalQuiet = const Duration(days: 30),
    this.syncIntervalReleaseSeason = const Duration(days: 1),
    this.offlineRetryInterval = const Duration(hours: 6),
  });

  /// 联网权威日期核对 + 11323 天星期连续性 + L4 差异报告的最小间隔。
  /// 本地算法已被 34 个 Rust 测试、11323 天连续、79093 次双实现比对锁死，
  /// 一周校准一次足够；更频繁地联网只增加启动开销，不会提高精度。
  final Duration verifyInterval;

  /// 平日的 L4 上游同步间隔（年度安排一年只发布一次）。
  final Duration syncIntervalQuiet;

  /// 11～1 月（次年安排发布窗口）的 L4 同步间隔。
  final Duration syncIntervalReleaseSeason;

  /// 上次核对为 offline 时的重试间隔：联网恢复后能补一次权威核对，
  /// 又不至于在持续离线时一天发 24 轮超时请求。
  final Duration offlineRetryInterval;

  static const String syncMarkerName = 'last-sync.txt';

  /// 按月份选择同步间隔。国务院通常在 11 月发布次年放假安排，
  /// 因此 11、12、1 月每天查一次，其余月份每月查一次。
  Duration syncIntervalFor(DateTime now) =>
      (now.month == 11 || now.month == 12 || now.month == 1)
          ? syncIntervalReleaseSeason
          : syncIntervalQuiet;

  /// 按上次核对结果选择报告复用间隔；抽成纯函数便于单元测试。
  Duration intervalFor(String status) =>
      status == 'offline' ? offlineRetryInterval : verifyInterval;

  /// 跨年（内置 L4 快照按年组织）或系统时钟回拨一律强制重跑。
  bool needsRecheck(DateTime? last, DateTime now) {
    if (last == null || now.isBefore(last)) {
      return true;
    }
    return last.year != now.year;
  }

  /// 无记录、超过间隔一律需要重新执行。
  bool shouldRun(DateTime? last, DateTime now, Duration interval) {
    if (last == null || now.isBefore(last)) {
      return true;
    }
    return now.difference(last) >= interval;
  }

  /// 读时间戳标记；缺失或损坏返回 null（当作需要执行）。
  DateTime? readMarker(File file) {
    try {
      if (!file.existsSync()) {
        return null;
      }
      return DateTime.tryParse(file.readAsStringSync().trim());
    } catch (_) {
      return null;
    }
  }

  void writeMarker(File file, DateTime now) {
    try {
      file.writeAsStringSync(now.toUtc().toIso8601String(), flush: true);
    } catch (_) {
      // 标记写不进去只影响节流，不影响日历本体
    }
  }

  static int monthKey(int year, int month) => year * 12 + month;
}

/// 月份结果缓存：翻回看过的月份不再启动 CLI 进程。
///
/// 最多保留 [maxEntries] 个月（默认一年），超出按插入顺序淘汰最早项。
/// L4 调休数据若被更新器改写，界面会调用 [clear] 强制重新取数，
/// 保证「节流」不会让日历显示过期数据。
class MonthCache<T> {
  MonthCache({this.maxEntries = 12});

  final int maxEntries;
  final Map<int, T> _items = <int, T>{};

  T? get(int year, int month) => _items[ResourcePolicy.monthKey(year, month)];

  void put(int year, int month, T value) {
    final int key = ResourcePolicy.monthKey(year, month);
    _items.remove(key);
    _items[key] = value;
    while (_items.length > maxEntries) {
      _items.remove(_items.keys.first);
    }
  }

  void clear() => _items.clear();

  int get length => _items.length;
}
