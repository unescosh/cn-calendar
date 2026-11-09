import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import 'calendar_bridge.dart';
import 'day_info.dart';
import 'verify_service.dart';

// 深色主题下的低饱和配色。分类口径见 DayInfo.dayKind，色块含义见底部图例。
const Color _kWorkdayText = Color(0xFFECEFF1);
const Color _kWeekendText = Color(0xFF9FB4FF);
const Color _kHolidayText = Color(0xFF81C784);
const Color _kMakeupText = Color(0xFFFFB74D);
const Color _kNationalText = Color(0xFFFF8A80);

const Color _kTransparent = Color(0x00000000);
const Color _kWeekendBg = Color(0x141E3A8A);
const Color _kHolidayBg = Color(0x142E7D32);
const Color _kMakeupBg = Color(0x22B26500);

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const CalendarApp());
}

class CalendarApp extends StatelessWidget {
  const CalendarApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '中国日历',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFFB03A2E),
          brightness: Brightness.dark,
        ),
      ),
      home: const CalendarPage(),
    );
  }
}

class CalendarPage extends StatefulWidget {
  const CalendarPage({super.key});

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

  @override
  void initState() {
    super.initState();
    final DateTime now = DateTime.now();
    _year = now.year;
    _month = now.month;
    _cacheDir = Directory(_cachePath());
    _cliPath = Platform.environment['CN_CAL_CLI'] ??
        CalendarBridge.defaultCliPath();
    _bridge = CalendarBridge(cliPath: _cliPath, cacheDir: _cacheDir.path);
    _loadMonth();
    _startVerification();
  }

  static String _cachePath() {
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
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final List<DayInfo> days = await _bridge.month(_year, _month);
      if (!mounted || seq != _loadSeq) {
        return;
      }
      setState(() {
        _days = days;
        _loading = false;
      });
    } catch (e) {
      if (!mounted || seq != _loadSeq) {
        return;
      }
      setState(() {
        _error = '$e';
        _loading = false;
      });
    }
  }

  void _shiftMonth(int delta) {
    setState(() {
      final int total = _year * 12 + (_month - 1) + delta;
      _year = total ~/ 12;
      _month = total % 12 + 1;
    });
    _loadMonth();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('$_year 年 $_month 月'),
        actions: <Widget>[
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
      body: _buildBody(),
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
            '无法读取日历核心，请检查 cn_cal_cli 是否可用。\n$_error',
            textAlign: TextAlign.center,
          ),
        ),
      );
    }
    return Column(
      children: <Widget>[
        _buildWeekHeader(),
        Expanded(child: _buildGrid()),
        _buildLegend(),
        Padding(
          padding: const EdgeInsets.all(8),
          child: Text(
            _verifying
                ? '正在静默核对日期与节日…'
                : (_verify?.label ?? '数据核对未运行'),
            style: const TextStyle(fontSize: 12),
          ),
        ),
      ],
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
                    child: Text(n, style: const TextStyle(fontSize: 12)),
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
          border: Border.all(color: Colors.white12, width: 0.5),
        ),
      );

  Widget _buildLegend() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: Wrap(
        alignment: WrapAlignment.center,
        spacing: 14,
        runSpacing: 2,
        children: <Widget>[
          _legendItem('工作日', _kWorkdayText, null),
          _legendItem('周末', _kWeekendText, _kWeekendBg),
          _legendItem('法定假期', _kHolidayText, _kHolidayBg),
          _legendItem('补班', _kMakeupText, _kMakeupBg),
          _legendItem('国家级纪念日', _kNationalText, null),
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
            color: background ?? _kTransparent,
            border: Border.all(color: foreground, width: 1),
            borderRadius: const BorderRadius.all(Radius.circular(2)),
          ),
        ),
        const SizedBox(width: 4),
        Text(text, style: TextStyle(fontSize: 10, color: foreground)),
      ],
    );
  }

  Widget _buildCell(DayInfo info) {
    final bool national = info.hasNationalMemorial;
    final DayKind kind = info.dayKind;
    Color background = _kTransparent;
    Color foreground = _kWorkdayText;
    if (kind == DayKind.makeup) {
      background = _kMakeupBg;
      foreground = _kMakeupText;
    } else if (kind == DayKind.holiday) {
      background = _kHolidayBg;
      foreground = _kHolidayText;
    } else if (kind == DayKind.weekend) {
      background = _kWeekendBg;
      foreground = _kWeekendText;
    }
    // 国家级纪念日优先级最高，压过周末 / 假期配色。
    final Color accent = national ? _kNationalText : foreground;
    return InkWell(
      onTap: () => _showDetail(info),
      child: Container(
        decoration: BoxDecoration(
          color: background,
          border: Border.all(color: Colors.white12, width: 0.5),
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
                    fontSize: 15,
                    color: accent,
                    fontWeight: national ? FontWeight.bold : FontWeight.normal,
                  ),
                ),
                const Spacer(),
                if (info.badge.isNotEmpty)
                  Text(
                    info.badge,
                    style: TextStyle(
                      fontSize: 10,
                      color: info.makeup ? _kMakeupText : _kHolidayText,
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 2),
            Text(
              info.primaryText,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 10, color: accent),
            ),
          ],
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
              const SizedBox(height: 8),
              ...info.labels.map((CalendarLabel l) => Text(
                    '${l.name}（${l.kind} · ${l.layer}）',
                    style: l.isNationalMemorial
                        ? const TextStyle(color: Color(0xFFFF8A80))
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
