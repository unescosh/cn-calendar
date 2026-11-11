#include "cn_calendar_p2.h"

#include <shellapi.h>

// Pure ASCII source on purpose. Chinese menu labels are written as \uXXXX
// escapes so MSVC's default codepage can never corrupt them.
//
// This translation unit is C-style on purpose: no STL containers, no lambdas,
// no templates, no exceptions. Fewer language features = fewer ways for a
// CI-only build (no local C++ toolchain on this machine) to break.

namespace CnCalendarP2 {
namespace {

const wchar_t kMutexName[] = L"Local\\CNCalendar_SingleInstance_Mutex";
const wchar_t kRegApp[] = L"Software\\CNCalendar";
const wchar_t kRegRun[] = L"Software\\Microsoft\\Windows\\CurrentVersion\\Run";
const wchar_t kRunValue[] = L"CnCalendar";
const wchar_t kHwndValue[] = L"MainWindowHwnd";
const wchar_t kHookValue[] = L"HookTaskbarClock";
const wchar_t kTrayClass[] = L"CNCalendar_TrayHost";
const wchar_t kClockClass[] = L"TrayClockWClass";  // Win10 tray clock

const UINT kMsgShow = WM_APP + 1;      // -> main window: show
const UINT kMsgExit = WM_APP + 2;      // -> main window: really quit
const UINT kMsgTray = WM_APP + 3;      // tray callback
const UINT kMsgShowHost = WM_APP + 4;  // -> tray host: show main window

const UINT kIdToggle = 1;
const UINT kIdHook = 2;
const UINT kIdAutostart = 3;
const UINT kIdExit = 4;

const wchar_t kTrayTip[] =
    L"\u4E2D\u56FD\u65E5\u5386\uFF08\u70B9\u51FB\u6253\u5F00\u6708\u5386\uFF09";
const wchar_t kTextOpen[] = L"\u6253\u5F00\u6708\u5386";
const wchar_t kTextHide[] = L"\u9690\u85CF\u6708\u5386";
const wchar_t kTextHook[] = L"\u63A5\u7BA1\u4EFB\u52A1\u680F\u65F6\u95F4";
const wchar_t kTextAutostart[] = L"\u5F00\u673A\u81EA\u542F";
const wchar_t kTextExit[] = L"\u9000\u51FA";

HANDLE g_mutex = NULL;
HWND g_main = NULL;
HWND g_host = NULL;
WNDPROC g_original_wndproc = NULL;
HHOOK g_hook = NULL;
HANDLE g_thread = NULL;
DWORD g_thread_id = 0;
NOTIFYICONDATAW g_nid = {};
UINT g_taskbar_created = 0;
bool g_hook_clock = true;
bool g_clock_pending = false;

// ---------- tiny helpers (no CRT secure-function dependency) ----------

bool WideEqual(const wchar_t* a, const wchar_t* b) {
  if (a == NULL || b == NULL) return false;
  size_t i = 0;
  while (a[i] != L'\0' || b[i] != L'\0') {
    if (a[i] != b[i]) return false;
    ++i;
  }
  return true;
}

void WriteDword(const wchar_t* name, DWORD value) {
  HKEY key = NULL;
  if (RegCreateKeyW(HKEY_CURRENT_USER, kRegApp, &key) != ERROR_SUCCESS) return;
  RegSetValueExW(key, name, 0, REG_DWORD,
                 reinterpret_cast<const BYTE*>(&value), sizeof(value));
  RegCloseKey(key);
}

bool ReadDword(const wchar_t* name, DWORD* out) {
  DWORD size = sizeof(DWORD);
  return RegGetValueW(HKEY_CURRENT_USER, kRegApp, name, RRF_RT_REG_DWORD,
                      NULL, out, &size) == ERROR_SUCCESS;
}

bool IsAutostartEnabled() {
  HKEY key = NULL;
  if (RegOpenKeyExW(HKEY_CURRENT_USER, kRegRun, 0, KEY_READ, &key) !=
      ERROR_SUCCESS) {
    return false;
  }
  DWORD type = 0;
  DWORD size = 0;
  LONG result =
      RegQueryValueExW(key, kRunValue, NULL, &type, NULL, &size);
  RegCloseKey(key);
  return result == ERROR_SUCCESS;
}

void SetAutostart(bool on) {
  HKEY key = NULL;
  if (RegOpenKeyExW(HKEY_CURRENT_USER, kRegRun, 0, KEY_WRITE, &key) !=
      ERROR_SUCCESS) {
    return;
  }
  if (on) {
    wchar_t path[MAX_PATH] = {};
    GetModuleFileNameW(NULL, path, MAX_PATH);
    wchar_t quoted[MAX_PATH + 4] = {};
    size_t i = 0;
    quoted[i++] = L'"';
    for (size_t j = 0; path[j] != L'\0' && i + 2 < MAX_PATH + 4; ++j) {
      quoted[i++] = path[j];
    }
    quoted[i++] = L'"';
    quoted[i] = L'\0';
    RegSetValueExW(key, kRunValue, 0, REG_SZ,
                   reinterpret_cast<const BYTE*>(quoted),
                   static_cast<DWORD>((i + 1) * sizeof(wchar_t)));
  } else {
    RegDeleteValueW(key, kRunValue);
  }
  RegCloseKey(key);
}

// ---------- main window ----------

void ShowMainWindow() {
  if (g_main != NULL && IsWindow(g_main)) {
    ShowWindow(g_main, SW_SHOWNORMAL);
    SetForegroundWindow(g_main);
  }
}

void ToggleMainWindow() {
  if (g_main != NULL && IsWindow(g_main) && IsWindowVisible(g_main)) {
    ShowWindow(g_main, SW_HIDE);
  } else {
    ShowMainWindow();
  }
}

LRESULT CALLBACK MainWindowProc(HWND hwnd, UINT msg, WPARAM wp, LPARAM lp) {
  if (msg == WM_CLOSE) {
    // Tray residency: the X button hides instead of terminating the process.
    ShowWindow(hwnd, SW_HIDE);
    return 0;
  }
  if (msg == kMsgShow) {
    ShowMainWindow();
    return 0;
  }
  if (msg == kMsgExit) {
    PostQuitMessage(0);
    return 0;
  }
  return CallWindowProcW(g_original_wndproc, hwnd, msg, wp, lp);
}

// ---------- tray host ----------

void ShowTrayMenu() {
  HMENU menu = CreatePopupMenu();
  if (menu == NULL) return;
  const wchar_t* toggle_text =
      (g_main != NULL && IsWindow(g_main) && IsWindowVisible(g_main))
          ? kTextHide
          : kTextOpen;
  AppendMenuW(menu, MF_STRING, kIdToggle, toggle_text);
  AppendMenuW(menu, MF_SEPARATOR, 0, NULL);
  AppendMenuW(menu, MF_STRING | (g_hook_clock ? MF_CHECKED : 0), kIdHook,
              kTextHook);
  AppendMenuW(menu, MF_STRING | (IsAutostartEnabled() ? MF_CHECKED : 0),
              kIdAutostart, kTextAutostart);
  AppendMenuW(menu, MF_SEPARATOR, 0, NULL);
  AppendMenuW(menu, MF_STRING, kIdExit, kTextExit);

  POINT pt = {};
  GetCursorPos(&pt);
  SetForegroundWindow(g_host);
  TrackPopupMenu(menu, TPM_LEFTALIGN | TPM_RIGHTBUTTON, pt.x, pt.y, 0, g_host,
                 NULL);
  DestroyMenu(menu);
}

LRESULT CALLBACK TrayHostProc(HWND hwnd, UINT msg, WPARAM wp, LPARAM lp) {
  if (msg == kMsgTray) {
    const UINT mouse = static_cast<UINT>(lp);
    if (mouse == WM_LBUTTONUP) {
      ToggleMainWindow();
    } else if (mouse == WM_RBUTTONUP) {
      ShowTrayMenu();
    }
    return 0;
  }
  if (msg == kMsgShowHost) {
    ShowMainWindow();
    return 0;
  }
  if (msg == WM_COMMAND) {
    switch (LOWORD(wp)) {
      case kIdToggle:
        ToggleMainWindow();
        break;
      case kIdHook:
        g_hook_clock = !g_hook_clock;
        g_clock_pending = false;
        WriteDword(kHookValue, g_hook_clock ? 1 : 0);
        break;
      case kIdAutostart:
        SetAutostart(!IsAutostartEnabled());
        break;
      case kIdExit:
        if (g_main != NULL && IsWindow(g_main)) {
          PostMessageW(g_main, kMsgExit, 0, 0);
        }
        break;
      default:
        break;
    }
    return 0;
  }
  if (g_taskbar_created != 0 && msg == g_taskbar_created) {
    // Explorer restarted: re-add the tray icon.
    Shell_NotifyIconW(NIM_ADD, &g_nid);
    return 0;
  }
  return DefWindowProcW(hwnd, msg, wp, lp);
}

// ---------- taskbar clock click ----------

bool IsClockPoint(POINT pt) {
  HWND window = WindowFromPoint(pt);
  for (int i = 0; i < 5 && window != NULL; ++i) {
    wchar_t cls[64] = {};
    GetClassNameW(window, cls, 64);
    if (WideEqual(cls, kClockClass)) return true;
    window = GetParent(window);
  }
  return false;
}

LRESULT CALLBACK LowLevelMouseProc(int code, WPARAM wp, LPARAM lp) {
  if (code == HC_ACTION) {
    const MSLLHOOKSTRUCT* info =
        reinterpret_cast<const MSLLHOOKSTRUCT*>(lp);
    if (info != NULL) {
      if (wp == WM_LBUTTONDOWN) {
        if (g_hook_clock && IsClockPoint(info->pt)) {
          g_clock_pending = true;
          return 1;  // swallow the press so Windows' own flyout stays closed
        }
      } else if (wp == WM_LBUTTONUP) {
        if (g_clock_pending) {
          g_clock_pending = false;
          if (g_host != NULL) {
            PostMessageW(g_host, kMsgShowHost, 0, 0);
          }
          return 1;  // swallow the release too, no half-click leaks through
        }
      }
    }
  }
  return CallNextHookEx(g_hook, code, wp, lp);
}

DWORD WINAPI TrayThread(LPVOID) {
  g_thread_id = GetCurrentThreadId();

  WNDCLASSW wc = {};
  wc.lpfnWndProc = TrayHostProc;
  wc.hInstance = GetModuleHandleW(NULL);
  wc.lpszClassName = kTrayClass;
  RegisterClassW(&wc);

  // A hidden top-level window (not HWND_MESSAGE) is used on purpose: it can
  // still receive the TaskbarCreated broadcast after Explorer restarts.
  g_host = CreateWindowExW(0, kTrayClass, L"CNCalendar Tray Host",
                           WS_OVERLAPPEDWINDOW, 0, 0, 0, 0, NULL, NULL,
                           GetModuleHandleW(NULL), NULL);
  g_taskbar_created = RegisterWindowMessageW(L"TaskbarCreated");

  if (g_host != NULL) {
    NOTIFYICONDATAW empty = {};
    g_nid = empty;
    g_nid.cbSize = sizeof(g_nid);
    g_nid.hWnd = g_host;
    g_nid.uID = 1;
    g_nid.uFlags = NIF_ICON | NIF_MESSAGE | NIF_TIP;
    g_nid.uCallbackMessage = kMsgTray;
    g_nid.hIcon = LoadIconW(GetModuleHandleW(NULL), MAKEINTRESOURCEW(101));
    if (g_nid.hIcon == NULL) {
      // IDI_APPLICATION expands via MAKEINTRESOURCE, whose type depends on
      // the UNICODE macro. Cast explicitly so this compiles either way.
      g_nid.hIcon = LoadIconW(NULL, reinterpret_cast<LPCWSTR>(IDI_APPLICATION));
    }
    size_t i = 0;
    for (; kTrayTip[i] != L'\0' && i + 1 < sizeof(g_nid.szTip) / sizeof(wchar_t);
         ++i) {
      g_nid.szTip[i] = kTrayTip[i];
    }
    g_nid.szTip[i] = L'\0';
    Shell_NotifyIconW(NIM_ADD, &g_nid);

    // WH_MOUSE_LL does not inject a DLL; the callback runs on this thread,
    // which owns the GetMessage loop below.
    g_hook = SetWindowsHookExW(WH_MOUSE_LL, LowLevelMouseProc,
                               GetModuleHandleW(NULL), 0);

    MSG msg;
    while (GetMessageW(&msg, NULL, 0, 0)) {
      TranslateMessage(&msg);
      DispatchMessageW(&msg);
    }
  }

  if (g_hook != NULL) {
    UnhookWindowsHookEx(g_hook);
    g_hook = NULL;
  }
  Shell_NotifyIconW(NIM_DELETE, &g_nid);
  return 0;
}

}  // namespace

bool ClaimSingleInstanceOrForward() {
  HANDLE mutex = CreateMutexW(NULL, TRUE, kMutexName);
  if (mutex == NULL) return true;  // degrade gracefully, never block launch

  if (GetLastError() == ERROR_ALREADY_EXISTS) {
    DWORD64 raw = 0;
    DWORD size = sizeof(raw);
    if (RegGetValueW(HKEY_CURRENT_USER, kRegApp, kHwndValue, RRF_RT_REG_QWORD,
                     NULL, &raw, &size) == ERROR_SUCCESS) {
      HWND hwnd = reinterpret_cast<HWND>(static_cast<ULONG_PTR>(raw));
      if (hwnd != NULL && IsWindow(hwnd)) {
        PostMessageW(hwnd, kMsgShow, 0, 0);
      }
    }
    CloseHandle(mutex);
    return false;
  }

  g_mutex = mutex;
  DWORD enabled = 1;
  if (ReadDword(kHookValue, &enabled)) {
    g_hook_clock = (enabled != 0);
  }
  return true;
}

void AttachMainWindow(HWND main_window) {
  g_main = main_window;
  if (g_main == NULL) return;

  g_original_wndproc = reinterpret_cast<WNDPROC>(SetWindowLongPtrW(
      g_main, GWLP_WNDPROC, reinterpret_cast<LONG_PTR>(MainWindowProc)));

  DWORD64 raw = static_cast<DWORD64>(reinterpret_cast<ULONG_PTR>(g_main));
  HKEY key = NULL;
  if (RegCreateKeyW(HKEY_CURRENT_USER, kRegApp, &key) == ERROR_SUCCESS) {
    RegSetValueExW(key, kHwndValue, 0, REG_QWORD,
                   reinterpret_cast<const BYTE*>(&raw), sizeof(raw));
    RegCloseKey(key);
  }

  g_thread = CreateThread(NULL, 0, TrayThread, NULL, 0, NULL);
}

void Shutdown() {
  if (g_thread_id != 0) {
    PostThreadMessageW(g_thread_id, WM_QUIT, 0, 0);
  }
  if (g_thread != NULL) {
    WaitForSingleObject(g_thread, 2000);
    CloseHandle(g_thread);
    g_thread = NULL;
  }
  if (g_main != NULL && g_original_wndproc != NULL && IsWindow(g_main)) {
    SetWindowLongPtrW(g_main, GWLP_WNDPROC,
                      reinterpret_cast<LONG_PTR>(g_original_wndproc));
    g_original_wndproc = NULL;
  }
  HKEY key = NULL;
  if (RegOpenKeyExW(HKEY_CURRENT_USER, kRegApp, 0, KEY_WRITE, &key) ==
      ERROR_SUCCESS) {
    RegDeleteValueW(key, kHwndValue);
    RegCloseKey(key);
  }
  if (g_mutex != NULL) {
    CloseHandle(g_mutex);
    g_mutex = NULL;
  }
}

}  // namespace CnCalendarP2
