#ifndef CN_CALENDAR_P2_H_
#define CN_CALENDAR_P2_H_

// P2 step 1: Windows 10 tray residency + taskbar clock click takeover.
// P2 step 2: transparent bottom-most desktop widget. Dart renders the month
//            off-screen into a bitmap; this module only blits it. The widget
//            window lives on the main thread's message loop and can be turned
//            off from the tray menu (HKCU\Software\CNCalendar\WidgetEnabled).
//
// Constraints (docs/P2 desktop shape plan):
//   * No system component is modified, disabled or injected. We only take
//     over the "user clicks the clock" action and show the SAME Flutter window.
//   * Everything lives in the main process. No extra resident process, no
//     background timer, no polling, no telemetry.
//   * The low level mouse hook is only called on real mouse events; the tray
//     only waits for messages. Idle cost is zero.
//   * If the hook is blocked by security software or a Windows update, the
//     tray icon remains a fully usable fallback entry point.
//
// This file is copied into the CI-generated app/windows/runner/ by
// apply_p2_patch.ps1. No Flutter 3.22 template file is overwritten; the
// patch only inserts exact strings.
//
// NOTE: source is intentionally pure ASCII (Chinese UI strings use \uXXXX
// escapes) so that MSVC's default codepage cannot corrupt it.

#include <windows.h>

namespace CnCalendarP2 {

// Call early in wWinMain, before the Flutter window is created.
// If another instance is already running, bring its window to front and
// return false; the caller must uninitialize COM (if already initialized)
// and return immediately. Otherwise take single-instance ownership.
bool ClaimSingleInstanceOrForward();

// Call after Win32Window::Create() succeeded. Saves the HWND, intercepts
// WM_CLOSE so the close button hides to tray instead of quitting, creates
// the tray icon/menu, and installs the low level mouse hook.
void AttachMainWindow(HWND main_window);

// Call before leaving the message loop. Removes hook, tray icon, subclass
// and the cached HWND from the registry.
void Shutdown();

}  // namespace CnCalendarP2

#endif  // CN_CALENDAR_P2_H_
