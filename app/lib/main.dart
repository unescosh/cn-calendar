import 'dart:async';
import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import 'calendar_bridge.dart';
import 'day_info.dart';
import 'verify_service.dart';

/// 切月过渡参数：整屏推入。
///
/// 2026-11-10 第四轮的「小位移 + 交叉淡入」在双端实机出现文字残影，
/// 根因是新旧两页半透明叠加、而格子底色本身也是半透明。第六轮改成
/// **两页各占一整屏、边界精确衔接、不做任何淡入**：任意时刻可见区域里
/// 两页首尾相接而不重叠，物理上不可能出现两层文字。
class CalendarMotion {
  const CalendarMotion._();

  static const Duration switchDuration = Duration(milliseconds: 220);

  /// 新页 / 旧页的起始纵向位移，单位是「自身高度」（1.0 = 一整屏）。
  /// direction = +1 去下个月：新页自下方整屏外滑入，旧页被推向上方；
  /// direction = -1 回上个月：方向完全相反。
  /// 出场页拿到的是反向动画 1→0，begin 取反号即可与入场页首尾衔接。
  static double pageOffset(int direction, {required bool incoming}) =>
      (incoming ? 1 : -1) * direction.toDouble();
}

/// 深色 / 白色两套配色。
/// 周末与法定假期的**日期数字**统一用橙红，比原来的淡蓝清楚得多；
/// 四类日子的区分仍由背景色承担（周末蓝、假期绿、补班橙）。
/// 分类口径见 DayInfo.dayKind，色块含义见底部图例。
class CalendarPalette {
  const CalendarPalette._({
    required this.text,
    required this.subText,
    required this.gridLine,
    required this.workdayNumber,
    required this.restNumber,
    required this.makeupNumber,
    required this.nationalNumber,
    required this.festivalLabel,
    required this.lunarLabel,
    required this.weekendBg,
    required this.holidayBg,
    required this.makeupBg,
    required this.badgeRestBg,
    required this.badgeRestFg,
    required this.badgeMakeupBg,
    required this.badgeMakeupFg,
    required this.selectedMonthBg,
    required this.selectedMonthFg,
  });

  final Color text;
  final Color subText;
  final Color gridLine;
  final Color workdayNumber;
  final Color restNumber;
  final Color makeupNumber;
  final Color nationalNumber;
  final Color festivalLabel;
  final Color lunarLabel;
  final Color weekendBg;
  final Color holidayBg;
  final Color makeupBg;
  final Color badgeRestBg;
  final Color badgeRestFg;
  final Color badgeMakeupBg;
  final Color badgeMakeupFg;
  final Color selectedMonthBg;
  final Color selectedMonthFg;

  static const CalendarPalette dark = CalendarPalette._(
    text: Color(0xFFECEFF1),
    subText: Color(0xFF9E9E9E),
    gridLine: Color(0x1FFFFFFF),
    workdayNumber: Color(0xFFECEFF1),
    restNumber: Color(0xFFFF8A65),
    makeupNumber: Color(0xFFFFB74D),
    nationalNumber: Color(0xFFFF5252),
    festivalLabel: Color(0xFFFFAB91),
    lunarLabel: Color(0xFFB0BEC5),
    weekendBg: Color(0x141E3A8A),
    holidayBg: Color(0x142E7D32),
    makeupBg: Color(0x22B26500),
    badgeRestBg: Color(0x3343A047),
    badgeRestFg: Color(0xFFC8E6C9),
    badgeMakeupBg: Color(0x33EF6C00),
    badgeMakeupFg: Color(0xFFFFE0B2),
    selectedMonthBg: Color(0x33FF8A65),
    selectedMonthFg: Color(0xFFFFAB91),
  );

  static const CalendarPalette light = CalendarPalette._(
    text: Color(0xFF212121),
    subText: Color(0xFF616161),
    gridLine: Color(0x22000000),
    workdayNumber: Color(0xFF212121),
    restNumber: Color(0xFFD84315),
    makeupNumber: Color(0xFFE65100),
    nationalNumber: Color(0xFFC62828),
    festivalLabel: Color(0xFFBF360C),
    lunarLabel: Color(0xFF616161),
    weekendBg: Color(0xFFEAF0FF),
    holidayBg: Color(0xFFE8F5E9),
    makeupBg: Color(0xFFFFF3E0),
    badgeRestBg: Color(0xFF43A047),
    badgeRestFg: Color(0xFFFFFFFF),
    badgeMakeupBg: Color(0xFFEF6C00),
    badgeMakeupFg: Color(0xFFFFFFFF),
    selectedMonthBg: Color(0xFFFFCCBC),
    selectedMonthFg: Color(0xFFBF360C),
  );
}

/// 用户级缓存目录：调休 JSON、核对报告、主题设置都放这里。
String cachePath() {
  final String? configured = Platform.environment['CN_CAL_CACHE_DIR'];
  if (configured != null) {
    return configured;
  }
  final String home = Platform.environment['USERPROFILE'] ??
      Platform.environment['HOME'] ??
      '.';
  return '$home${Platform.pathSeparator}.cn_calendar'
      '${Platform.pathSeparator}cache';
}

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const CalendarApp());
}

class CalendarApp extends StatefulWidget {
  const CalendarApp({super.key});

  @override
  State<CalendarApp> createState() => _CalendarAppState();
}

class _CalendarAppState extends State<CalendarApp> {
  bool _dark = true;

  @override
  void initState() {
    super.initState();
    unawaited(_loadTheme());
  }

  Future<void> _loadTheme() async {
    try {
      final File f = File(
          '${cachePath()}${Platform.pathSeparator}theme.txt');
      final String saved = (await f.readAsString()).trim();
      if (mounted && saved == 'light') {
        setState(() => _dark = false);
      }
    } catch (_) {
      // 没有设置文件 / 只读环境：保持默认黑色模式。
    }
  }

  Future<void> _toggleTheme() async {
    final bool next = !_dark;
    setState(() => _dark = next);
    try {
      final Directory dir = Directory(cachePath());
      await dir.create(recursive: true);
      await File('${dir.path}${Platform.pathSeparator}theme.txt')
          .writeAsString(next ? 'dark' : 'light');
    } catch (_) {
      // 写不进去时本次切换仍然生效，只是下次启动不记忆。
    }
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '中国日历',
      debugShowCheckedModeBanner: false,
      theme: _theme(_dark),
      home: CalendarPage(
        darkMode: _dark,
        onToggleTheme: _toggleTheme,
      ),
    );
  }

  static ThemeData _theme(bool dark) {
    return ThemeData(
      useMaterial3: true,
      colorScheme: ColorScheme.fromSeed(
        seedColor: const Color(0xFFB03A2E),
        brightness: dark ? Brightness.dark : Brightness.light,
      ),
      scaffoldBackgroundColor:
          dark ? const Color(0xFF1C1A19) : const Color(0xFFFAFAFA),
      appBarTheme: AppBarTheme(
        backgroundColor:
            dark ? const Color(0xFF1C1A19) : const Color(0xFFF2F2F2),
        foregroundColor:
            dark ? const Color(0xFFECEFF1) : const Color(0xFF212121),
      ),
    );
  }
}

class CalendarPage extends StatefulWidget {
  const CalendarPage({
    super.key,
    required this.darkMode,
    required this.onToggleTheme,
  });

  final bool darkMode;
  final Future<void> Function() onToggleTheme;

  @override
  State<CalendarPage> createState() => _CalendarPageState();
}

class _CalendarPageState extends State<CalendarPage> {
  late int _year;
  late int _month;
  late CalendarBridge _bridge;
  late Directory _cacheDir;
  late String _cliPath;

  List<DayInfo> _days = <DayInfo>[];
  String? _error;
  bool _loading = true;
  VerifySummary? _verify;
  bool _verifying = true;
  // 并发刷新保护：L4 更新后重取当月数据，旧请求的结果不得覆盖新结果。
  int _loadSeq = 0;
  // 一次滚轮手势会连发多个事件，250ms 内只翻一页。
  DateTime? _lastWheel;
  // 切月方向：+1 去下个月（新页自下方进），-1 回上个月（自上方进）。
  int _slideDirection = 1;
  // AnimatedSwitcher 的 key 绑定「真正到位的数据」，避免新月份数据还没到
  // 就先播动画、格子里却还留着旧月份。
  String _shownMonthKey = '';

  CalendarPalette get _palette =>
      widget.darkMode ? CalendarPalette.dark : CalendarPalette.light;

  @override
  void initState() {
    super.initState();
    final DateTime now = DateTime.now();
    _year = now.year;
    _month = now.month;
    _cacheDir = Directory(cachePath());
    _cliPath = Platform.environment['CN_CAL_CLI'] ??
        CalendarBridge.defaultCliPath();
    _bridge = CalendarBridge(cliPath: _cliPath, cacheDir: _cacheDir.path);
    _loadMonth();
    _startVerification();
  }

  void _startVerification({bool force = false}) {
    // 后台执行：不阻塞首屏，失败也不弹窗。
    // force=true 是用户点「立即校准」：跳过定期节流，但仍走同一套完整核对。
    if (force && mounted) {
      setState(() => _verifying = true);
    }
    unawaited(() async {
      final VerifySummary summary = await VerifyService(
        cacheDir: _cacheDir,
        cliPath: _cliPath,
      ).run(force: force);
      if (!mounted) {
        return;
      }
      setState(() {
        _verify = summary;
        _verifying = false;
      });
      if (summary.dataChanged) {
        // 上游调休刚被改写：此前的月份结果来自旧缓存，必须整体失效并重取，
        // 否则「定期校准节流」会让界面显示过期的放假/补班安排。
        _bridge.clearCache();
        await _loadMonth();
      }
    }());
  }

  Future<void> _loadMonth() async {
    final int seq = ++_loadSeq;
    // 只有首屏（还没显示过任何月份）才转圈。换月时保留旧格子，
    // 等新数据到位再播整屏推入，避免中间闪一下进度圈打断过渡。
    if (_shownMonthKey.isEmpty) {
      setState(() {
        _loading = true;
        _error = null;
      });
    }
    try {
      final List<DayInfo> days = await _bridge.month(_year, _month);
      if (!mounted || seq != _loadSeq) {
        return;
      }
      setState(() {
        _days = days;
        _shownMonthKey = '$_year-$_month';
        _error = null;
        _loading = false;
      });
    } catch (e) {
      if (!mounted || seq != _loadSeq) {
        return;
      }
      setState(() {
        _error = e.toString().replaceFirst('Bad state: ', '');
        _loading = false;
      });
    }
  }

  void _shiftMonth(int delta) {
    _slideDirection = delta > 0 ? 1 : -1;
    setState(() {
      final int total = _year * 12 + (_month - 1) + delta;
      _year = total ~/ 12;
      _month = total % 12 + 1;
    });
    _loadMonth();
  }

  /// 鼠标滚轮翻月：向上滚回上个月，向下滚去下个月。
  void _onPointerSignal(PointerSignalEvent event) {
    if (event is! PointerScrollEvent) {
      return;
    }
    final double dy = event.scrollDelta.dy;
    if (dy.abs() < 1) {
      return;
    }
    final DateTime now = DateTime.now();
    if (_lastWheel != null &&
        now.difference(_lastWheel!).inMilliseconds < 250) {
      return;
    }
    _lastWheel = now;
    _shiftMonth(dy > 0 ? 1 : -1);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: _buildTitle(),
        actions: <Widget>[
          IconButton(
            icon: Icon(widget.darkMode
                ? Icons.light_mode_outlined
                : Icons.dark_mode_outlined),
            tooltip: widget.darkMode ? '切换到白色模式' : '切换到黑色模式',
            onPressed: () => unawaited(widget.onToggleTheme()),
          ),
          IconButton(
            icon: Icon(_verifyIcon()),
            tooltip: _verifying ? '正在核对数据' : (_verify?.label ?? '数据核对'),
            onPressed: _showVerification,
          ),
          IconButton(
            icon: const Icon(Icons.chevron_left),
            tooltip: '上个月',
            onPressed: () => _shiftMonth(-1),
          ),
          IconButton(
            icon: const Icon(Icons.chevron_right),
            tooltip: '下个月',
            onPressed: () => _shiftMonth(1),
          ),
        ],
      ),
      body: Listener(
        onPointerSignal: _onPointerSignal,
        child: _buildBody(),
      ),
    );
  }

  /// 左上角的「2026 年 11 月」可点击，直接跳到任意年份与月份。
  Widget _buildTitle() {
    return InkWell(
      onTap: () => unawaited(_showMonthPicker()),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Text(
              '$_year 年 $_month 月',
              style:
                  const TextStyle(fontSize: 20, fontWeight: FontWeight.w600),
            ),
            const SizedBox(width: 4),
            const Icon(Icons.arrow_drop_down, size: 18),
          ],
        ),
      ),
    );
  }

  IconData _verifyIcon() {
    if (_verifying) {
      return Icons.sync;
    }
    switch (_verify?.status) {
      case 'consistent':
        return Icons.verified_outlined;
      case 'differences':
        return Icons.error_outline;
      default:
        return Icons.cloud_off_outlined;
    }
  }

  Widget _buildBody() {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            '无法读取日历核心。\n$_error',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 14, color: _palette.text),
          ),
        ),
      );
    }
    return Column(
      children: <Widget>[
        _buildWeekHeader(),
        Expanded(
          child: AnimatedSwitcher(
            duration: CalendarMotion.switchDuration,
            // 两页必须同步：曲线要关于 (0.5, 0.5) 中心对称，
            // 否则入场页与出场页速度不同，中间会露出底色缝隙或短暂重叠。
            // easeOutCubic 不对称，禁止改回去；linear / easeInOut 可以。
            switchInCurve: Curves.easeInOut,
            switchOutCurve: Curves.easeInOut,
            // RepaintBoundary 让整屏推入独立重绘，ClipRect 裁掉滑出
            // 可见区的那一页，不溢到星期行 / 图例，也不留脏矩形残影。
            layoutBuilder:
                (Widget? currentChild, List<Widget> previousChildren) =>
                    RepaintBoundary(
              child: ClipRect(
                child: Stack(
                  fit: StackFit.expand,
                  children: <Widget>[
                    ...previousChildren,
                    if (currentChild != null) currentChild,
                  ],
                ),
              ),
            ),
            transitionBuilder: _monthTransition,
            child: KeyedSubtree(
              key: ValueKey<String>(_shownMonthKey),
              // 每页垫不透明底：即使有亚像素缝隙，也不会透出另一页文字。
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: Theme.of(context).scaffoldBackgroundColor,
                ),
                child: _buildGrid(),
              ),
            ),
          ),
        ),
        _buildLegend(),
        Padding(
          padding: const EdgeInsets.all(8),
          child: Text(
            _verifying
                ? '正在静默核对日期与节日…'
                : (_verify?.label ?? '数据核对未运行'),
            style: TextStyle(fontSize: 12, color: _palette.subText),
          ),
        ),
      ],
    );
  }

  /// 整屏推入：新页与旧页各占一整屏、首尾衔接，没有任何淡入或透明度叠加。
  /// 用方法 tear-off 传给 AnimatedSwitcher，引用稳定；位移在 entry 创建时
  /// 固化进 Tween，动画播放期间不会被后续滚轮事件改写。
  Widget _monthTransition(Widget child, Animation<double> animation) {
    // Flutter 3.22 把原始 child 交给 transitionBuilder，key 保持不变；
    // 据此区分入场页与出场页（出场页拿到的是反向动画 1→0）。
    final bool incoming = child.key == ValueKey<String>(_shownMonthKey);
    final double begin = CalendarMotion.pageOffset(
      _slideDirection,
      incoming: incoming,
    );
    return SlideTransition(
      position: Tween<Offset>(
        begin: Offset(0, begin),
        end: Offset.zero,
      ).animate(animation),
      child: child,
    );
  }

  Widget _buildWeekHeader() {
    // 固定周日开头、周六结束，与核心 weekday 0=周日…6=周六 一致，不要改成周一开头。
    const List<String> names = <String>['日', '一', '二', '三', '四', '五', '六'];
    return Row(
      children: names
          .map((String n) => Expanded(
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: Center(
                    child: Text(
                      n,
                      style:
                          TextStyle(fontSize: 12, color: _palette.subText),
                    ),
                  ),
                ),
              ))
          .toList(),
    );
  }

  /// 整月一屏铺满：按当月实际行数动态分配高度，不再出现
  /// 「默认窗口只看得到前三周、月底要靠滚动」的问题（UOS 复跑实测反馈）。
  Widget _buildGrid() {
    final int leading = _days.isEmpty ? 0 : _days.first.weekday;
    final int rows = ((leading + _days.length) / 7).ceil();
    if (rows == 0) {
      return const SizedBox.shrink();
    }
    final List<Widget> cells = <Widget>[
      for (int i = 0; i < leading; i++) _emptyCell(),
      ..._days.map(_buildCell),
    ];
    while (cells.length < rows * 7) {
      cells.add(_emptyCell());
    }
    return Column(
      children: <Widget>[
        for (int r = 0; r < rows; r++)
          Expanded(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                for (int c = 0; c < 7; c++) Expanded(child: cells[r * 7 + c]),
              ],
            ),
          ),
      ],
    );
  }

  Widget _emptyCell() => Container(
        decoration: BoxDecoration(
          border: Border.all(color: _palette.gridLine, width: 0.5),
        ),
      );

  Widget _buildLegend() {
    final CalendarPalette p = _palette;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: Wrap(
        alignment: WrapAlignment.center,
        spacing: 14,
        runSpacing: 2,
        children: <Widget>[
          _legendItem('工作日', p.workdayNumber, null),
          _legendItem('周末', p.restNumber, p.weekendBg),
          _legendItem('法定假期', p.restNumber, p.holidayBg),
          _legendItem('补班', p.makeupNumber, p.makeupBg),
          _legendItem('国家级纪念日', p.nationalNumber, null),
        ],
      ),
    );
  }

  Widget _legendItem(String text, Color foreground, Color? background) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Container(
          width: 10,
          height: 10,
          decoration: BoxDecoration(
            color: background ?? Colors.transparent,
            border: Border.all(color: foreground, width: 1),
            borderRadius: const BorderRadius.all(Radius.circular(2)),
          ),
        ),
        const SizedBox(width: 4),
        Text(
          text,
          style: TextStyle(fontSize: 10, color: _palette.subText),
        ),
      ],
    );
  }

  Widget _buildCell(DayInfo info) {
    final CalendarPalette p = _palette;
    final bool national = info.hasNationalMemorial;
    final DayKind kind = info.dayKind;
    Color background = Colors.transparent;
    Color numberColor = p.workdayNumber;
    if (kind == DayKind.makeup) {
      background = p.makeupBg;
      numberColor = p.makeupNumber;
    } else if (kind == DayKind.holiday) {
      background = p.holidayBg;
      numberColor = p.restNumber;
    } else if (kind == DayKind.weekend) {
      background = p.weekendBg;
      numberColor = p.restNumber;
    }
    // 国家级纪念日优先级最高，压过周末 / 假期配色。
    if (national) {
      numberColor = p.nationalNumber;
    }
    final bool emphasized =
        national || info.festivalDay || info.hasFestivalLabel;
    return InkWell(
      onTap: () => _showDetail(info),
      child: Container(
        decoration: BoxDecoration(
          color: background,
          border: Border.all(color: p.gridLine, width: 0.5),
        ),
        padding: const EdgeInsets.all(4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                Text(
                  '${info.date.day}',
                  style: TextStyle(
                    fontSize: 17,
                    color: numberColor,
                    fontWeight:
                        emphasized ? FontWeight.w800 : FontWeight.w600,
                  ),
                ),
                const Spacer(),
                if (info.badge.isNotEmpty) _buildBadge(info, p),
              ],
            ),
            const SizedBox(height: 2),
            Text(
              info.primaryText,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 11,
                fontWeight: info.hasFestivalLabel
                    ? FontWeight.w700
                    : FontWeight.normal,
                color: info.hasFestivalLabel
                    ? (national ? p.nationalNumber : p.festivalLabel)
                    : p.lunarLabel,
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 「休 / 班」是提醒上班与休假的关键角标，字号与字重都要压过其他文字。
  Widget _buildBadge(DayInfo info, CalendarPalette p) {
    final bool makeup = info.makeup;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
      decoration: BoxDecoration(
        color: makeup ? p.badgeMakeupBg : p.badgeRestBg,
        borderRadius: const BorderRadius.all(Radius.circular(4)),
      ),
      child: Text(
        info.badge,
        style: TextStyle(
          fontSize: 13,
          fontWeight: FontWeight.w900,
          color: makeup ? p.badgeMakeupFg : p.badgeRestFg,
        ),
      ),
    );
  }

  /// 点左上角标题：年份左右切换，月份一次点选到位。
  Future<void> _showMonthPicker() async {
    const int minYear = 2020;
    const int maxYear = 2050;
    int pickedYear = _year;
    final List<int>? picked = await showDialog<List<int>>(
      context: context,
      builder: (_) => StatefulBuilder(
        builder: (BuildContext ctx, StateSetter setDialogState) => AlertDialog(
          title: const Text('跳转年月'),
          content: SizedBox(
            width: 320,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: <Widget>[
                    IconButton(
                      icon: const Icon(Icons.chevron_left),
                      tooltip: '上一年',
                      onPressed: pickedYear > minYear
                          ? () => setDialogState(() => pickedYear--)
                          : null,
                    ),
                    Text(
                      '$pickedYear 年',
                      style: const TextStyle(
                          fontSize: 18, fontWeight: FontWeight.bold),
                    ),
                    IconButton(
                      icon: const Icon(Icons.chevron_right),
                      tooltip: '下一年',
                      onPressed: pickedYear < maxYear
                          ? () => setDialogState(() => pickedYear++)
                          : null,
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                GridView.count(
                  shrinkWrap: true,
                  crossAxisCount: 4,
                  childAspectRatio: 1.7,
                  mainAxisSpacing: 6,
                  crossAxisSpacing: 6,
                  physics: const NeverScrollableScrollPhysics(),
                  children: <Widget>[
                    for (int m = 1; m <= 12; m++)
                      _monthButton(
                        month: m,
                        selected: pickedYear == _year && m == _month,
                        onTap: () =>
                            Navigator.of(ctx).pop(<int>[pickedYear, m]),
                      ),
                  ],
                ),
                const SizedBox(height: 8),
                const Text(
                  '农历数据覆盖 2020–2050 年；鼠标滚轮也可上下翻月。',
                  style: TextStyle(fontSize: 11),
                ),
              ],
            ),
          ),
          actions: <Widget>[
            TextButton(
              onPressed: () {
                final DateTime now = DateTime.now();
                Navigator.of(ctx).pop(<int>[now.year, now.month]);
              },
              child: const Text('回到本月'),
            ),
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('取消'),
            ),
          ],
        ),
      ),
    );
    if (picked == null || picked.length != 2) {
      return;
    }
    if (picked[0] == _year && picked[1] == _month) {
      return;
    }
    // 跳到未来月份与滚轮下滚同向，跳回过去与上滚同向。
    final int from = _year * 12 + _month;
    final int to = picked[0] * 12 + picked[1];
    _slideDirection = to >= from ? 1 : -1;
    setState(() {
      _year = picked[0];
      _month = picked[1];
    });
    _loadMonth();
  }

  Widget _monthButton({
    required int month,
    required bool selected,
    required VoidCallback onTap,
  }) {
    final CalendarPalette p = _palette;
    return Material(
      color: selected ? p.selectedMonthBg : Colors.transparent,
      borderRadius: const BorderRadius.all(Radius.circular(6)),
      child: InkWell(
        onTap: onTap,
        borderRadius: const BorderRadius.all(Radius.circular(6)),
        child: Center(
          child: Text(
            '$month 月',
            style: TextStyle(
              fontSize: 13,
              fontWeight: selected ? FontWeight.bold : FontWeight.normal,
              color: selected ? p.selectedMonthFg : null,
            ),
          ),
        ),
      ),
    );
  }

  void _showDetail(DayInfo info) {
    showDialog<void>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        title: Text(
            '${info.date.year} 年 ${info.date.month} 月 ${info.date.day} 日'),
        content: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Text('星期：${_weekdayName(info.weekday)}　${info.workday ? '工作日' : '休息日'}'),
              if (info.lunar != null) Text('农历：${info.lunar!.text}'),
              if (info.jieqi != null) Text('节气：${info.jieqi}'),
              if (info.ganzhi != null) Text('干支：${info.ganzhi} · ${info.shengxiao}'),
              if (info.holidayName != null)
                Text(info.festivalDay
                    ? '节日正日：${info.holidayName}'
                    : '法定假期：${info.holidayName}（假期内，非节日当天）'),
              const SizedBox(height: 8),
              ...info.labels.map((CalendarLabel l) => Text(
                    '${l.name}（${l.kind} · ${l.layer}）',
                    style: l.isNationalMemorial
                        ? TextStyle(color: _palette.nationalNumber)
                        : null,
                  )),
            ],
          ),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('关闭'),
          ),
        ],
      ),
    );
  }

  void _showVerification() {
    final VerifySummary? summary = _verify;
    showDialog<void>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        title: Text(summary?.label ?? '正在核对'),
        content: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              if (summary == null)
                const Text('正在用联网数据核对日期、星期与节日，结果稍后显示。')
              else ...<Widget>[
                Text('核对时间：${summary.checkedAt.toLocal()}'),
                const SizedBox(height: 8),
                ...summary.checks.map((String s) => Text(s,
                    style: const TextStyle(fontSize: 12))),
                if (summary.differences.isNotEmpty) ...<Widget>[
                  const SizedBox(height: 8),
                  const Text('差异：', style: TextStyle(color: Colors.orange)),
                  ...summary.differences.map((String s) => Text(s,
                      style: const TextStyle(fontSize: 12))),
                ],
                const SizedBox(height: 8),
                const Text('本地纪念日、农历与节气不会被联网数据改写。',
                    style: TextStyle(fontSize: 12)),
                const Text('平时自动定期校准；点「立即校准」可随时完整核对一次。',
                    style: TextStyle(fontSize: 12)),
              ],
            ],
          ),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: _verifying
                ? null
                : () {
                    Navigator.of(context).pop();
                    _startVerification(force: true);
                  },
            child: const Text('立即校准'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('关闭'),
          ),
        ],
      ),
    );
  }

  static String _weekdayName(int w) {
    const List<String> names = <String>['日', '一', '二', '三', '四', '五', '六'];
    return '星期${names[w]}';
  }
}
