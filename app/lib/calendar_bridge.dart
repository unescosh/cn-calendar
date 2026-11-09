import 'dart:convert';
import 'dart:io';

import 'day_info.dart';

/// 过渡桥接：通过 cn_cal_cli 取得 Rust 核心的计算结果。
/// P2 会换成 FFI 动态库调用，但 JSON 契约保持不变，界面层无需改动。
class CalendarBridge {
  const CalendarBridge({required this.cliPath, this.cacheDir});

  final String cliPath;
  /// 静默更新器的缓存目录，通过 CN_CAL_HOLIDAY_DIR 传给核心。
  final String? cacheDir;

  /// 优先取与主程序同目录的 CLI（打包后两者放在一起），
  /// 找不到再退回 PATH，方便开发期直接 `cargo build` 后运行。
  static String defaultCliPath() {
    final String name = Platform.isWindows ? 'cn_cal_cli.exe' : 'cn_cal_cli';
    final String sibling =
        '${File(Platform.resolvedExecutable).parent.path}'
        '${Platform.pathSeparator}$name';
    return File(sibling).existsSync() ? sibling : name;
  }

  Future<List<DayInfo>> month(int year, int month) async {
    final Map<String, String>? env = cacheDir == null
        ? null
        : <String, String>{'CN_CAL_HOLIDAY_DIR': cacheDir!};
    final ProcessResult result = await Process.run(
      cliPath,
      <String>['month', '$year', '$month'],
      environment: env,
    );
    if (result.exitCode != 0) {
      throw StateError('日历核心执行失败：${result.stderr}');
    }
    final List<dynamic> decoded =
        jsonDecode(result.stdout as String) as List<dynamic>;
    return decoded
        .map((dynamic e) => DayInfo.fromJson(e as Map<String, dynamic>))
        .toList();
  }
}
