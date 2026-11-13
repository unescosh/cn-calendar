import 'dart:async';
import 'dart:ffi' as ffi;
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'day_info.dart';

typedef _PostMessageWNative = ffi.Int32 Function(
    ffi.IntPtr, ffi.Uint32, ffi.IntPtr, ffi.IntPtr);
typedef _PostMessageWDart = int Function(int, int, int, int);

/// P2 第 2 步：Windows 10 桌面挂件的数据 / 位图发布端。
///
/// 设计口径（docs/P2第二步_Win10桌面挂件.md）：
///  * 单向、事件驱动。Dart 把整月画成一张位图，原生层只负责贴图，
///    不在 C++ 里重写一遍月历、不解析 JSON、不碰 Flutter embedder API。
///  * 不新增进程、不新增线程、不联网。原生窗口由主消息循环驱动，
///    静止时没有 WM_PAINT，也没有周期轮询。
///  * 主界面的颜色由 [palette] 传入（ARGB 整数），配色只有一份来源。
///  * 非 Windows 平台整段 no-op：UOS 产物一个字节都不受影响。
///  * 挂件是增强能力，任何异常都静默降级，绝不阻塞主界面。
///
/// 数据流：publish() → widget_image.bin → PostMessageW → 原生 WndProc
/// 读文件 → CreateDIBSection → BitBlt。通知在文件写完之后才发出，
/// 因此原生层永远不会读到半张图。
class DesktopWidget {
  const DesktopWidget._();

  static const int width = 448;
  static const int height = 424;

  static const double _cellW = 64.0;
  static const double _cellH = 58.0;
  static const double _gridTop = 68.0;
  static const int _cols = 7;
  static const int _rows = 6;

  /// 'CWWG'，自定义位图头的魔数。
  static const int _magic = 0x47475743;
  /// WM_APP + 5，与 cn_calendar_p2.cpp 的 kMsgRefreshWidget 一致。
  static const int refreshMessage = 0x8005;

  static const String imageFileName = 'widget_image.bin';
  static const String hwndFileName = 'widget_hwnd.txt';
  /// 一行式排障记录：实机出问题时用户把这个文件发回来即可定位，
  /// 不需要装任何开发工具，也不需要在界面上弹错误框。
  static const String statusFileName = 'widget_status.txt';

  // 由 main.dart 的 CalendarPalette 传入，顺序必须与 _widgetPalette() 一致。
  static const int pText = 0;
  static const int pSubText = 1;
  static const int pGridLine = 2;
  static const int pWorkdayNumber = 3;
  static const int pRestNumber = 4;
  static const int pMakeupNumber = 5;
  static const int pNationalNumber = 6;
  static const int pFestivalLabel = 7;
  static const int pLunarLabel = 8;
  static const int pWeekendBg = 9;
  static const int pHolidayBg = 10;
  static const int pMakeupBg = 11;
  static const int pBadgeRestBg = 12;
  static const int pBadgeRestFg = 13;
  static const int pBadgeMakeupBg = 14;
  static const int pBadgeMakeupFg = 15;
  static const int pSelectedMonthBg = 16;
  static const int pSelectedMonthFg = 17;
  static const int paletteSize = 18;

  static const String _fontFamily = 'Microsoft YaHei';

  static _PostMessageWDart? _postMessage;

  /// 只在 Windows 上才解析 user32.dll，Linux / UOS 不会触碰 FFI。
  static _PostMessageWDart? get _post {
    if (!Platform.isWindows) {
      return null;
    }
    _postMessage ??= ffi.DynamicLibrary.open('user32.dll')
        .lookupFunction<_PostMessageWNative, _PostMessageWDart>('PostMessageW');
    return _postMessage;
  }

  /// 把当月数据画成一张 32bpp BGRA 位图并通知原生挂件窗口。
  ///
  /// [palette] 是 18 个 ARGB 整数，来自 CalendarPalette，避免把配色常量
  /// 复制到第二处。任何失败都静默返回：主界面不受挂件影响。
  static Future<void> publish({
    required List<DayInfo> days,
    required int year,
    required int month,
    required bool dark,
    required String cacheDir,
    required List<int> palette,
  }) async {
    if (!Platform.isWindows || palette.length != paletteSize) {
      return;
    }
    // 每一步都留痕：挂件是增强能力，异常一律静默降级，但必须能事后定位。
    final List<String> trace = <String>['start'];
    try {
      final ui.Image image = await _render(
        days: days,
        year: year,
        month: month,
        dark: dark,
        palette: palette,
        today: DateTime.now(),
      );
      trace.add('render-ok');
      final ByteData? rgba =
          await image.toByteData(format: ui.ImageByteFormat.rawRgba);
      if (rgba == null) {
        trace.add('rgba-null');
        return;
      }
      trace.add('rgba-ok');
      final Uint8List bytes = _toBgra(rgba);
      final Directory dir = Directory(cacheDir);
      if (!dir.existsSync()) {
        dir.createSync(recursive: true);
      }
      // 必须显式取 dir.path！dart:io 的 Directory.toString() 返回
      // "Directory: '路径'"，把它直接插进字符串会生成带冒号的非法
      // Windows 路径，writeAsBytesSync 抛 FileSystemException 并被静默吞掉，
      // 实机表现就是「窗口建好了，widget_image.bin 永远不出现、挂件全透明」。
      final File imageFile = File(
          '${dir.path}${Platform.pathSeparator}$imageFileName');
      imageFile.writeAsBytesSync(bytes, flush: true);
      trace.add('bitmap-ok ${bytes.length}');

      final int? hwnd = await _readHwnd(dir.path);
      if (hwnd == null) {
        trace.add('hwnd-missing');
        return;
      }
      trace.add('hwnd=$hwnd');
      final _PostMessageWDart? post = _post;
      if (post != null) {
        post(hwnd, refreshMessage, 0, 0);
        trace.add('posted');
      } else {
        trace.add('ffi-missing');
      }
    } catch (e) {
      // 挂件是增强能力；缺字体、缺权限、窗口尚未创建都不得影响主界面。
      trace.add('error:${e.runtimeType} $e');
    } finally {
      _writeStatus(cacheDir, trace.join(' | '));
    }
  }

  /// 只写一行状态，不联网、不弹窗、不常驻。写失败也不影响主界面。
  static void _writeStatus(String cacheDir, String line) {
    try {
      final Directory dir = Directory(cacheDir);
      if (!dir.existsSync()) {
        dir.createSync(recursive: true);
      }
      File('${dir.path}${Platform.pathSeparator}$statusFileName')
          .writeAsStringSync('${DateTime.now().toIso8601String()} $line\n',
              flush: true);
    } catch (_) {
      // 诊断文件本身写不进去也不影响任何功能。
    }
  }

  /// 日期哨兵：每 30 分钟只比一次「年-月-日」字符串，日期没变零动作。
  /// 日期变化（跨天 / 跨月 / 跨年 / 时钟回拨）才回调一次重新发布当月，
  /// 不联网、不重绘主窗口、不常驻动画。非 Windows 返回 null。
  static Timer? startDaySentinel(Future<void> Function() onDateChanged) {
    if (!Platform.isWindows) {
      return null;
    }
    String last = _dateKey(DateTime.now());
    return Timer.periodic(const Duration(minutes: 30), (Timer _) {
      final String now = _dateKey(DateTime.now());
      if (now == last) {
        return;
      }
      last = now;
      unawaited(onDateChanged());
    });
  }

  static String _dateKey(DateTime d) => '${d.year}-${d.month}-${d.day}';

  /// 原生层在 AttachMainWindow 里写 HWND 文件，可能略晚于 Dart 首屏，
  /// 所以启动瞬间做几次短重试（3 秒封顶），不做后台常驻等待。
  /// 原生窗口创建后也会自己补发一次刷新，双向兜住这个竞态。
  static Future<int?> _readHwnd(String dir) async {
    final File file =
        File('$dir${Platform.pathSeparator}$hwndFileName');
    for (int i = 0; i < 12; i++) {
      if (file.existsSync()) {
        final int? value =
            int.tryParse(file.readAsStringSync().trim(), radix: 16);
        if (value != null && value != 0) {
          return value;
        }
      }
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }
    return null;
  }

  /// 自定义头 16 字节 + BGRA 像素。alpha 恒为 255：整体半透明由原生层的
  /// SetLayeredWindowAttributes(LWA_ALPHA) 统一处理，因此这里既不需要
  /// premultiply，也不受 rawRgba 是否预乘影响。
  static Uint8List _toBgra(ByteData rgba) {
    final Uint8List src = Uint8List.view(
        rgba.buffer, rgba.offsetInBytes, rgba.lengthInBytes);
    final int pixels = width * height;
    final Uint8List out = Uint8List(16 + pixels * 4);
    final ByteData head = ByteData.view(out.buffer);
    head.setUint32(0, _magic, Endian.little);
    head.setUint32(4, width, Endian.little);
    head.setUint32(8, height, Endian.little);
    head.setUint32(12, 0, Endian.little);
    for (int i = 0; i < pixels; i++) {
      final int s = i * 4;
      final int d = 16 + s;
      out[d] = src[s + 2];      // B
      out[d + 1] = src[s + 1];  // G
      out[d + 2] = src[s];      // R
      out[d + 3] = 255;         // A
    }
    return out;
  }

  static Future<ui.Image> _render({
    required List<DayInfo> days,
    required int year,
    required int month,
    required bool dark,
    required List<int> palette,
    required DateTime today,
  }) async {
    final ui.PictureRecorder recorder = ui.PictureRecorder();
    final ui.Canvas canvas = ui.Canvas(recorder);
    _paint(canvas, days, year, month, dark, palette, today);
    final ui.Picture picture = recorder.endRecording();
    return picture.toImage(width, height);
  }

  static void _paint(
    ui.Canvas canvas,
    List<DayInfo> days,
    int year,
    int month,
    bool dark,
    List<int> palette,
    DateTime today,
  ) {
    // 必须先铺满不透明底色：之后所有像素 alpha 都是 255。
    final ui.Color cardBg =
        ui.Color(dark ? 0xFF1C1A19 : 0xFFFAFAFA);
    canvas.drawRect(
      ui.Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
      ui.Paint()..color = cardBg,
    );

    final ui.Color line = ui.Color(palette[pGridLine]);
    final ui.Color subText = ui.Color(palette[pSubText]);
    final ui.Color titleColor = ui.Color(palette[pText]);

    // 标题
    _text(canvas, '$year 年 $month 月', 16, 10, 260, 20, titleColor,
        bold: true);
    _text(canvas, '\u4E2D\u56FD\u684C\u9762\u65E5\u5386', width - 150, 14,
        134, 11, subText, align: ui.TextAlign.right);
    canvas.drawLine(const ui.Offset(12, 40), const ui.Offset(436.0, 40),
        ui.Paint()..color = line);

    // 周日起，与主界面 _buildWeekHeader 一致。
    const List<String> weekNames = <String>['日', '一', '二', '三', '四', '五', '六'];
    for (int c = 0; c < _cols; c++) {
      _text(canvas, weekNames[c], c * _cellW, 45, _cellW, 12,
          c == 0 || c == 6 ? ui.Color(palette[pRestNumber]) : subText,
          align: ui.TextAlign.center, bold: true);
    }

    final int leading = days.isEmpty ? 0 : days.first.weekday;
    int rows = ((leading + days.length) / 7).ceil();
    if (rows > _rows) {
      rows = _rows;
    }
    if (rows < 1) {
      rows = 1;
    }
    for (int r = 0; r < _rows; r++) {
      for (int c = 0; c < _cols; c++) {
        final int index = r * _cols + c - leading;
        final double x = c * _cellW;
        final double y = _gridTop + r * _cellH;
        final ui.Rect cell =
            ui.Rect.fromLTWH(x + 1, y + 1, _cellW - 2, _cellH - 2);
        if (index < 0 || index >= days.length || r >= rows) {
          _cellFrame(canvas, cell, line);
          continue;
        }
        _paintCell(canvas, cell, days[index], palette, today, line);
      }
    }
  }

  static void _cellFrame(ui.Canvas canvas, ui.Rect cell, ui.Color line) {
    canvas.drawRect(
      cell,
      ui.Paint()
        ..color = line
        ..style = ui.PaintingStyle.stroke
        ..strokeWidth = 1,
    );
  }

  static void _paintCell(
    ui.Canvas canvas,
    ui.Rect cell,
    DayInfo info,
    List<int> palette,
    DateTime today,
    ui.Color line,
  ) {
    ui.Color background = const ui.Color(0x00000000);
    ui.Color numberColor = ui.Color(palette[pWorkdayNumber]);
    switch (info.dayKind) {
      case DayKind.makeup:
        background = ui.Color(palette[pMakeupBg]);
        numberColor = ui.Color(palette[pMakeupNumber]);
        break;
      case DayKind.holiday:
        background = ui.Color(palette[pHolidayBg]);
        numberColor = ui.Color(palette[pRestNumber]);
        break;
      case DayKind.weekend:
        background = ui.Color(palette[pWeekendBg]);
        numberColor = ui.Color(palette[pRestNumber]);
        break;
      case DayKind.workday:
        break;
    }
    if (info.hasNationalMemorial) {
      numberColor = ui.Color(palette[pNationalNumber]);
    }
    canvas.drawRect(cell, ui.Paint()..color = background);

    final bool isToday = info.date.year == today.year &&
        info.date.month == today.month &&
        info.date.day == today.day;
    if (isToday) {
      canvas.drawRRect(
        ui.RRect.fromRectAndRadius(
            cell.deflate(2), const ui.Radius.circular(6)),
        ui.Paint()..color = ui.Color(palette[pSelectedMonthBg]),
      );
    }
    _cellFrame(canvas, cell, line);

    final bool emphasized =
        info.hasNationalMemorial || info.festivalDay || info.hasFestivalLabel;
    _text(canvas, '${info.date.day}', cell.left + 5, cell.top + 3, 26, 17,
        isToday ? ui.Color(palette[pSelectedMonthFg]) : numberColor,
        bold: emphasized || isToday);

    if (info.badge.isNotEmpty) {
      final bool makeup = info.makeup;
      final ui.Rect badge = ui.Rect.fromLTWH(
          cell.right - 22, cell.top + 4, 18, 15);
      canvas.drawRRect(
        ui.RRect.fromRectAndRadius(badge, const ui.Radius.circular(3)),
        ui.Paint()
          ..color = ui.Color(palette[
              makeup ? pBadgeMakeupBg : pBadgeRestBg]),
      );
      _text(canvas, info.badge, badge.left, badge.top + 1, badge.width, 10,
          ui.Color(palette[makeup ? pBadgeMakeupFg : pBadgeRestFg]),
          align: ui.TextAlign.center, bold: true);
    }

    _text(
      canvas,
      info.primaryText,
      cell.left + 5,
      cell.top + 23,
      cell.width - 10,
      10,
      info.hasFestivalLabel
          ? (info.hasNationalMemorial
              ? ui.Color(palette[pNationalNumber])
              : ui.Color(palette[pFestivalLabel]))
          : ui.Color(palette[pLunarLabel]),
      bold: info.hasFestivalLabel,
      maxLines: 2,
    );
  }

  static void _text(
    ui.Canvas canvas,
    String value,
    double x,
    double y,
    double maxWidth,
    double size,
    ui.Color color, {
    bool bold = false,
    ui.TextAlign align = ui.TextAlign.left,
    int maxLines = 1,
  }) {
    final ui.ParagraphBuilder builder = ui.ParagraphBuilder(
      ui.ParagraphStyle(
        textAlign: align,
        fontFamily: _fontFamily,
        fontSize: size,
        maxLines: maxLines,
        ellipsis: '\u2026',
      ),
    )
      ..pushStyle(ui.TextStyle(
        color: color,
        fontSize: size,
        fontFamily: _fontFamily,
        fontWeight: bold ? ui.FontWeight.w700 : ui.FontWeight.w400,
      ))
      ..addText(value);
    final ui.Paragraph paragraph = builder.build()
      ..layout(ui.ParagraphConstraints(width: maxWidth));
    canvas.drawParagraph(paragraph, ui.Offset(x, y));
  }
}
