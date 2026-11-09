import 'package:flutter/services.dart';

/// P2 预留：托盘图标与桌面透明置顶挂件走平台通道。
/// - Windows 10：Win32 分层窗口（WS_EX_LAYERED）+ Shell_NotifyIcon
/// - 统信 UOS 20：X11 ARGB visual + _NET_WM_STATE_ABOVE + StatusNotifierItem
///
/// P1 阶段原生侧尚未实现，MissingPluginException 一律静默忽略，
/// 保证纯 Flutter 界面在双端都能独立运行。
class DesktopBridge {
  const DesktopBridge._();

  static const MethodChannel _channel = MethodChannel('cn_calendar/desktop');

  static Future<void> setWidgetVisible(bool visible) async {
    try {
      await _channel.invokeMethod<void>(
        'setWidgetVisible',
        <String, dynamic>{'visible': visible},
      );
    } on MissingPluginException {
      // 原生插件尚未接入
    } on PlatformException {
      // 平台不支持该能力时保持窗口形态
    }
  }

  static Future<void> showTrayMenu() async {
    try {
      await _channel.invokeMethod<void>('showTrayMenu');
    } on MissingPluginException {
      // 原生插件尚未接入
    } on PlatformException {
      // 平台不支持该能力时保持窗口形态
    }
  }
}
