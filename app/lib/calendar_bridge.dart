import 'dart:convert';
import 'dart:io';

import 'day_info.dart';
import 'resource_policy.dart';

/// 过渡桥接：通过 cn_cal_cli 取得 Rust 核心的计算结果。
/// P2 会换成 FFI 动态库调用，但 JSON 契约保持不变，界面层无需改动。
///
/// 已加载的月份在内存中复用（最多 12 个月），翻回看过的月份不再启动
/// CLI 进程。L4 调休数据更新后界面会调用 [clearCache] 强制重新取数。
class CalendarBridge {
  CalendarBridge({
    required this.cliPath,
    this.cacheDir,
    MonthCache<List<DayInfo>>? cache,
  }) : _cache = cache ?? MonthCache<List<DayInfo>>();

  final String cliPath;
  /// 静默更新器的缓存目录，通过 CN_CAL_HOLIDAY_DIR 传给核心。
  final String? cacheDir;

  final MonthCache<List<DayInfo>> _cache;

  /// 找计算核心。正常成品包里 CLI 与主程序同目录，一次命中即可。
  ///
  /// 旧版 CI 产物 `cn-calendar-windows-x64` 把主程序放在
  /// `app/build/windows/x64/runner/Release/`，把 CLI 放在
  /// `core/target/release/`，两者相隔数层；这里向上回溯有限层数并下探
  /// 这两个约定目录，让误下旧包的用户也能直接跑起来。
  /// 全部找不到才退回裸名交给 PATH（开发期用法）。
  static String defaultCliPath() {
    final String name = Platform.isWindows ? 'cn_cal_cli.exe' : 'cn_cal_cli';
    final String sep = Platform.pathSeparator;
    final Directory exeDir = File(Platform.resolvedExecutable).parent;
    final List<String> candidates = <String>[
      '${exeDir.path}$sep$name',
      '${exeDir.path}${sep}data$sep$name',
    ];
    // Release → x64 → windows → build → app → 解压根目录 → 上级目录，
    // 7 层足够覆盖旧 artifact 的 `core/target/release/` 布局。
    Directory? dir = exeDir;
    for (int i = 0; i < 7 && dir != null; i++) {
      candidates.add('${dir.path}$sep$name');
      candidates.add(
          '${dir.path}${sep}core${sep}target${sep}release$sep$name');
      candidates.add('${dir.path}${sep}core${sep}target${sep}debug$sep$name');
      dir = dir.parent;
    }
    for (final String path in candidates) {
      if (File(path).existsSync()) {
        return path;
      }
    }
    return name;
  }

  /// 子进程环境。传 environment 时 Dart 会**整体替换**父进程环境，
  /// 所以必须把 Platform.environment 一起带上，否则裸名 CLI 会因
  /// 缺少 PATH 在 Windows 上报「系统找不到指定的文件」。
  static Map<String, String>? childEnvironment(String? cacheDir) {
    if (cacheDir == null) {
      return null; // null = 完整继承父进程环境
    }
    return <String, String>{
      ...Platform.environment,
      'CN_CAL_HOLIDAY_DIR': cacheDir,
    };
  }

  /// L4 数据变化后调用，避免显示过期的调休安排。
  void clearCache() => _cache.clear();

  Future<List<DayInfo>> month(int year, int month) async {
    final List<DayInfo>? hit = _cache.get(year, month);
    if (hit != null) {
      return hit;
    }
    late final ProcessResult result;
    try {
      result = await Process.run(
        cliPath,
        <String>['month', '$year', '$month'],
        environment: childEnvironment(cacheDir),
        // Rust 核心输出 UTF-8。中文 Windows 的 systemEncoding 是 GBK，
        // 用默认值解码会把「丙午」「寒衣节」变成非法字符，
        // jsonDecode 随即抛 FormatException（Win10 实机截图已复现）。
        stdoutEncoding: utf8,
        stderrEncoding: utf8,
      );
    } on ProcessException catch (e) {
      throw StateError(
        '找不到日历核心：$cliPath\n'
        '请把 cn_cal_cli.exe 放在 cn_calendar.exe 旁边；'
        '若被安全软件隔离，请恢复该文件并加信任。\n'
        '原始错误：${e.message}',
      );
    }
    if (result.exitCode != 0) {
      throw StateError('日历核心执行失败（$cliPath）：${result.stderr}');
    }
    final List<DayInfo> days = parseMonth(result.stdout as String);
    _cache.put(year, month, days);
    return days;
  }

  /// 解析核心的整月 JSON。抽成公开静态方法，让回归测试能直接锁定
  /// 「UTF-8 中文一个字都不能丢」这条契约，见 [month] 里的 stdoutEncoding。
  static List<DayInfo> parseMonth(String stdout) {
    final List<dynamic> decoded = jsonDecode(stdout) as List<dynamic>;
    return decoded
        .map((dynamic e) => DayInfo.fromJson(e as Map<String, dynamic>))
        .toList();
  }
}
