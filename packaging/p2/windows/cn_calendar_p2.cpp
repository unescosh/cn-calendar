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

// ---------- desktop widget (P2 step 2) ----------
//
// The widget is a read-only bitmap mirror of the month grid. Dart renders
// off-screen (ui.PictureRecorder), writes widget_image.bin, then posts
// kMsgRefreshWidget through user32!PostMessageW. This side only blits.
// No JSON parsing, no fonts, no Flutter embedder API, no extra thread:
// the window lives on the main thread's existing GetMessage loop.

#ifndef WS_EX_NOACTIVATE
#define WS_EX_NOACTIVATE 0x08000000L
#endif
#ifndef LWA_ALPHA
#define LWA_ALPHA 0x00000002
#endif

const wchar_t kWidgetClass[] = L"CNCalendar_WidgetHost";
const wchar_t kWidgetValue[] = L"WidgetEnabled";
const wchar_t kWidgetImageFile[] = L"widget_image.bin";
const wchar_t kWidgetHwndFile[] = L"widget_hwnd.txt";
// Chinese menu label: desktop widget.
const wchar_t kTextWidget[] = L"\u684C\u9762\u6302\u4EF6";

const UINT kMsgRefreshWidget = WM_APP + 5;  // Dart -> widget
const UINT kMsgWidgetToggle = WM_APP + 6;   // tray  -> widget
const UINT kIdWidget = 5;

const DWORD kWidgetMagic = 0x47475743;  // 'CWWG'
const int kWidgetWidth = 448;
const int kWidgetHeight = 424;

HWND g_widget = NULL;
HDC g_widget_dc = NULL;
HBITMAP g_widget_bitmap = NULL;
HGDIOBJ g_widget_old = NULL;
int g_widget_w = 0;
int g_widget_h = 0;
volatile bool g_widget_enabled = true;

void AppendWide(wchar_t* dst, size_t cap, const wchar_t* add) {
  size_t i = 0;
  while (dst[i] != L'\0' && i + 1 < cap) ++i;
  size_t j = 0;
  while (add[j] != L'\0' && i + 1 < cap) dst[i++] = add[j++];
  dst[i] = L'\0';
}

// Mirrors cachePath() in main.dart, including the CN_CAL_CACHE_DIR override.
void GetCacheFilePath(const wchar_t* name, wchar_t* out, size_t cap) {
  DWORD got = GetEnvironmentVariableW(L"CN_CAL_CACHE_DIR", out,
                                      static_cast<DWORD>(cap));
  if (got == 0 || got >= cap) {
    GetEnvironmentVariableW(L"USERPROFILE", out, static_cast<DWORD>(cap));
    AppendWide(out, cap, L"\\.cn_calendar\\cache");
  }
  AppendWide(out, cap, L"\\");
  AppendWide(out, cap, name);
}

void EnsureCacheDir() {
  wchar_t dir[MAX_PATH] = {};
  DWORD got = GetEnvironmentVariableW(L"CN_CAL_CACHE_DIR", dir, MAX_PATH);
  if (got == 0 || got >= MAX_PATH) {
    GetEnvironmentVariableW(L"USERPROFILE", dir, MAX_PATH);
    AppendWide(dir, MAX_PATH, L"\\.cn_calendar");
    CreateDirectoryW(dir, NULL);
    AppendWide(dir, MAX_PATH, L"\\cache");
  }
  CreateDirectoryW(dir, NULL);  // harmless if it already exists
}

// Dart reads this as a hex string via int.tryParse(..., radix: 16).
void WriteWidgetHwnd(HWND hwnd) {
  wchar_t path[MAX_PATH] = {};
  GetCacheFilePath(kWidgetHwndFile, path, MAX_PATH);
  ULONG_PTR value = reinterpret_cast<ULONG_PTR>(hwnd);
  const wchar_t* hex = L"0123456789ABCDEF";
  char ascii[32] = {};
  wchar_t reversed[32] = {};
  int len = 0;
  if (value == 0) {
    reversed[len++] = L'0';
  }
  while (value != 0 && len < 31) {
    reversed[len++] = hex[value & 0xF];
    value >>= 4;
  }
  for (int i = 0; i < len; ++i) {
    ascii[i] = static_cast<char>(reversed[len - 1 - i]);
  }
  ascii[len] = '\0';
  HANDLE file = CreateFileW(path, GENERIC_WRITE, 0, NULL, CREATE_ALWAYS,
                            FILE_ATTRIBUTE_NORMAL, NULL);
  if (file == INVALID_HANDLE_VALUE) return;
  DWORD written = 0;
  WriteFile(file, ascii, static_cast<DWORD>(len), &written, NULL);
  CloseHandle(file);
}

void FreeWidgetBitmap() {
  if (g_widget_dc != NULL) {
    if (g_widget_old != NULL) SelectObject(g_widget_dc, g_widget_old);
    DeleteDC(g_widget_dc);
    g_widget_dc = NULL;
  }
  if (g_widget_bitmap != NULL) {
    DeleteObject(g_widget_bitmap);
    g_widget_bitmap = NULL;
  }
  g_widget_old = NULL;
  g_widget_w = 0;
  g_widget_h = 0;
}

// File layout: DWORD magic, DWORD width, DWORD height, DWORD reserved,
// then width*height*4 bytes of BGRA with alpha forced to 255. The whole
// window translucency comes from SetLayeredWindowAttributes(LWA_ALPHA),
// so no premultiplied alpha handling is needed here.
bool LoadWidgetBitmap() {
  wchar_t path[MAX_PATH] = {};
  GetCacheFilePath(kWidgetImageFile, path, MAX_PATH);
  HANDLE file = CreateFileW(path, GENERIC_READ,
                            FILE_SHARE_READ | FILE_SHARE_WRITE, NULL,
                            OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, NULL);
  if (file == INVALID_HANDLE_VALUE) return false;

  DWORD head[4] = {};
  DWORD read = 0;
  if (!ReadFile(file, head, sizeof(head), &read, NULL) ||
      read != sizeof(head) || head[0] != kWidgetMagic) {
    CloseHandle(file);
    return false;
  }
  const int w = static_cast<int>(head[1]);
  const int h = static_cast<int>(head[2]);
  if (w <= 0 || h <= 0 || w > 4096 || h > 4096) {
    CloseHandle(file);
    return false;
  }
  const DWORD pixels = static_cast<DWORD>(w) * static_cast<DWORD>(h) * 4;

  HDC screen = GetDC(NULL);
  if (screen == NULL) {
    CloseHandle(file);
    return false;
  }
  BITMAPINFO bi = {};
  bi.bmiHeader.biSize = sizeof(BITMAPINFOHEADER);
  bi.bmiHeader.biWidth = w;
  bi.bmiHeader.biHeight = -h;  // negative = top-down rows
  bi.bmiHeader.biPlanes = 1;
  bi.bmiHeader.biBitCount = 32;
  bi.bmiHeader.biCompression = BI_RGB;
  void* bits = NULL;
  HBITMAP bitmap =
      CreateDIBSection(screen, &bi, DIB_RGB_COLORS, &bits, NULL, 0);
  ReleaseDC(NULL, screen);
  if (bitmap == NULL || bits == NULL) {
    if (bitmap != NULL) DeleteObject(bitmap);
    CloseHandle(file);
    return false;
  }
  DWORD total = 0;
  const bool ok = ReadFile(file, bits, pixels, &total, NULL) != FALSE &&
                  total == pixels;
  CloseHandle(file);
  if (!ok) {
    DeleteObject(bitmap);
    return false;
  }

  HDC dc = CreateCompatibleDC(NULL);
  if (dc == NULL) {
    DeleteObject(bitmap);
    return false;
  }
  HGDIOBJ old = SelectObject(dc, bitmap);
  FreeWidgetBitmap();
  g_widget_dc = dc;
  g_widget_bitmap = bitmap;
  g_widget_old = old;
  g_widget_w = w;
  g_widget_h = h;
  return true;
}

LRESULT CALLBACK WidgetWndProc(HWND hwnd, UINT msg, WPARAM wp, LPARAM lp) {
  if (msg == kMsgRefreshWidget) {
    if (!g_widget_enabled) return 0;
    if (LoadWidgetBitmap()) {
      SetWindowPos(hwnd, HWND_BOTTOM, 0, 0, g_widget_w, g_widget_h,
                   SWP_NOMOVE | SWP_NOACTIVATE | SWP_SHOWWINDOW);
      InvalidateRect(hwnd, NULL, FALSE);
    }
    return 0;
  }
  if (msg == kMsgWidgetToggle) {
    g_widget_enabled = (wp != 0);
    ShowWindow(hwnd, g_widget_enabled ? SW_SHOW : SW_HIDE);
    if (g_widget_enabled) {
      PostMessageW(hwnd, kMsgRefreshWidget, 0, 0);
    }
    return 0;
  }
  if (msg == WM_PAINT) {
    PAINTSTRUCT ps = {};
    HDC hdc = BeginPaint(hwnd, &ps);
    if (hdc != NULL) {
      if (g_widget_dc != NULL && g_widget_bitmap != NULL) {
        BitBlt(hdc, 0, 0, g_widget_w, g_widget_h, g_widget_dc, 0, 0,
               SRCCOPY);
      }
      EndPaint(hwnd, &ps);
    }
    return 0;
  }
  if (msg == WM_DESTROY) {
    FreeWidgetBitmap();
    return 0;
  }
  return DefWindowProcW(hwnd, msg, wp, lp);
}

void InitWidget() {
  DWORD enabled = 1;
  if (ReadDword(kWidgetValue, &enabled)) {
    g_widget_enabled = (enabled != 0);
  }
  EnsureCacheDir();

  WNDCLASSW wc = {};
  wc.lpfnWndProc = WidgetWndProc;
  wc.hInstance = GetModuleHandleW(NULL);
  wc.lpszClassName = kWidgetClass;
  wc.hbrBackground = NULL;
  if (RegisterClassW(&wc) == 0 &&
      GetLastError() != ERROR_CLASS_ALREADY_EXISTS) {
    return;
  }

  RECT work = {};
  if (!SystemParametersInfoW(SPI_GETWORKAREA, 0, &work, 0)) {
    work.right = GetSystemMetrics(SM_CXSCREEN);
    work.bottom = GetSystemMetrics(SM_CYSCREEN);
  }
  int x = work.right - kWidgetWidth - 24;
  int y = work.bottom - kWidgetHeight - 24;
  if (x < work.left) x = work.left + 8;
  if (y < work.top) y = work.top + 8;

  g_widget = CreateWindowExW(
      WS_EX_LAYERED | WS_EX_NOACTIVATE | WS_EX_TRANSPARENT | WS_EX_TOOLWINDOW,
      kWidgetClass, L"CNCalendar Widget", WS_POPUP, x, y, kWidgetWidth,
      kWidgetHeight, NULL, NULL, GetModuleHandleW(NULL), NULL);
  if (g_widget == NULL) return;

  SetLayeredWindowAttributes(g_widget, 0, 216, LWA_ALPHA);
  SetWindowPos(g_widget, HWND_BOTTOM, 0, 0, 0, 0,
               SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE | SWP_SHOWWINDOW);
  if (!g_widget_enabled) ShowWindow(g_widget, SW_HIDE);
  WriteWidgetHwnd(g_widget);
  // Dart may publish the bitmap before this window exists and give up
  // waiting for the HWND file. Refresh once here so the widget is never
  // left blank by that race. No new timer / thread is introduced.
  if (g_widget_enabled) {
    PostMessageW(g_widget, kMsgRefreshWidget, 0, 0);
  }
}

void ShutdownWidget() {
  FreeWidgetBitmap();
  if (g_widget != NULL) {
    DestroyWindow(g_widget);
    g_widget = NULL;
  }
  wchar_t path[MAX_PATH] = {};
  GetCacheFilePath(kWidgetHwndFile, path, MAX_PATH);
  DeleteFileW(path);
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
  AppendMenuW(menu, MF_STRING | (g_widget_enabled ? MF_CHECKED : 0),
              kIdWidget, kTextWidget);
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
      case kIdWidget:
        g_widget_enabled = !g_widget_enabled;
        WriteDword(kWidgetValue, g_widget_enabled ? 1 : 0);
        if (g_widget != NULL) {
          PostMessageW(g_widget, kMsgWidgetToggle,
                       g_widget_enabled ? 1 : 0, 0);
        }
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

  // Widget is created on this (main) thread, so WM_PAINT / WM_APP refresh
  // messages are dispatched by wWinMain's existing GetMessage loop.
  InitWidget();
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
  ShutdownWidget();
  if (g_mutex != NULL) {
    CloseHandle(g_mutex);
    g_mutex = NULL;
  }
}

}  // namespace CnCalendarP2
