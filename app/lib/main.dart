import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import 'calendar_bridge.dart';
import 'day_info.dart';
import 'verify_service.dart';

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

  void _startVerification() {
    // 后台执行：不阻塞首屏，失败也不弹窗
    unawaited(() async {
      final VerifySummary summary = await VerifyService(
        cacheDir: _cacheDir,
        cliPath: _cliPath,
      ).run();
      if (!mounted) {
        return;
      }
      setState(() {
        _verify = summary;
        _verifying = false;
      });
    }());
  }

  Future<void> _loadMonth() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final List<DayInfo> days = await _bridge.month(_year, _month);
      if (!mounted) {
        return;
      }
      setState(() {
        _days = days;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) {
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

  Widget _buildGrid() {
    final int leading = _days.isEmpty ? 0 : _days.first.weekday;
    final List<Widget> cells = <Widget>[
      for (int i = 0; i < leading; i++) const SizedBox.shrink(),
      ..._days.map(_buildCell),
    ];
    return GridView.count(
      crossAxisCount: 7,
      childAspectRatio: 0.78,
      children: cells,
    );
  }

  Widget _buildCell(DayInfo info) {
    final bool national = info.hasNationalMemorial;
    final Color? accent =
        national ? const Color(0xFFFF8A80) : null;
    return InkWell(
      onTap: () => _showDetail(info),
      child: Container(
        decoration: BoxDecoration(
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
                      color: info.makeup ? Colors.orange : Colors.green,
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 2),
            Text(
              info.primaryText,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 10, color: accent ?? Colors.white70),
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
              ],
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

  static String _weekdayName(int w) {
    const List<String> names = <String>['日', '一', '二', '三', '四', '五', '六'];
    return '星期${names[w]}';
  }
}
