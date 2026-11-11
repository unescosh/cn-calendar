# P2 step 1: patch the CI-generated Flutter 3.22 Windows runner.
#
# Why a patch instead of committing the runner directory: this project lets
# `flutter create --platforms=windows` generate the platform shell on every
# CI run. Never overwriting a template file keeps the CMake/Flutter glue
# exactly at the version Flutter generates; we only append one new .cpp and
# insert four exact strings into main.cpp / CMakeLists.txt.
#
# Every replacement is asserted. If Flutter changes its template, this script
# fails with a precise message instead of silently producing an unpatched exe.
#
# Pure ASCII + UTF-8 (no BOM) on purpose: PowerShell 5.1 defaults to UTF-16
# for Set-Content, which would break both CMake and MSVC input files.

param(
  # Optional override, used by local dry-run validation of this patch script.
  [string]$RunnerDir = ''
)

$ErrorActionPreference = 'Stop'

$repo = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..')).Path
$src = Join-Path $repo 'packaging/p2/windows'
$runner = if ($RunnerDir -ne '') { $RunnerDir } else { Join-Path $repo 'app/windows/runner' }
$cmakePath = Join-Path $runner 'CMakeLists.txt'
$mainPath = Join-Path $runner 'main.cpp'

foreach ($p in @($cmakePath, $mainPath)) {
  if (-not (Test-Path $p)) {
    throw "runner file missing: $p (flutter create must run before this patch)"
  }
}

foreach ($f in @('cn_calendar_p2.cpp', 'cn_calendar_p2.h')) {
  $from = Join-Path $src $f
  if (-not (Test-Path $from)) { throw "P2 source missing: $from" }
  Copy-Item $from (Join-Path $runner $f) -Force
}

$utf8 = New-Object System.Text.UTF8Encoding($false)

function Read-Normalized([string]$path) {
  # GitHub checkout may convert LF to CRLF on Windows. Normalize to LF first
  # so every exact needle below matches deterministically.
  return [System.IO.File]::ReadAllText($path).Replace("`r`n", "`n")
}

function Write-Normalized([string]$path, [string]$text) {
  [System.IO.File]::WriteAllText($path, $text, $utf8)
}

function Assert-Contains([string]$text, [string]$needle, [string]$label) {
  if (-not $text.Contains($needle)) {
    throw "patch check failed [$label]: missing [$needle]"
  }
}

# ---------------- CMakeLists.txt ----------------
$cmake = Read-Normalized $cmakePath
if ($cmake.Contains('cn_calendar_p2.cpp')) {
  throw 'CMakeLists.txt already patched; run flutter create on a clean tree'
}

$cmakeNeedle = '  "win32_window.cpp"'
Assert-Contains $cmake $cmakeNeedle 'cmake source list'
$cmake = $cmake.Replace($cmakeNeedle, $cmakeNeedle + "`n" + '  "cn_calendar_p2.cpp"')
$cmake = $cmake + "`n" +
  '# P2 step 1: tray icon + low level mouse hook need shell32/advapi32.' + "`n" +
  'target_link_libraries(${BINARY_NAME} PRIVATE "shell32.lib" "advapi32.lib")' + "`n" +
  '# Flutter enables /WX for runner sources. Our file is a self-contained' + "`n" +
  '# Win32 shim; keep warnings non-fatal for this translation unit only.' + "`n" +
  'set_source_files_properties("cn_calendar_p2.cpp" PROPERTIES COMPILE_OPTIONS "/W3;/WX-")' + "`n"
Assert-Contains $cmake 'cn_calendar_p2.cpp' 'cmake patched source'
Assert-Contains $cmake 'shell32.lib' 'cmake patched libs'
Assert-Contains $cmake 'COMPILE_OPTIONS' 'cmake warning policy'
Write-Normalized $cmakePath $cmake

# ---------------- main.cpp ----------------
$main = Read-Normalized $mainPath
if ($main.Contains('cn_calendar_p2.h')) {
  throw 'main.cpp already patched; run flutter create on a clean tree'
}

# 1) include
$n1 = '#include "utils.h"'
Assert-Contains $main $n1 'main include'
$main = $main.Replace($n1, $n1 + "`n" + '#include "cn_calendar_p2.h"')

# 2) single instance check, before the Dart project / window is created
$n2 = '  flutter::DartProject project(L"data");'
$a2 = '  if (!CnCalendarP2::ClaimSingleInstanceOrForward()) {' + "`n" +
      '    ::CoUninitialize();' + "`n" +
      '    return EXIT_SUCCESS;' + "`n" +
      '  }' + "`n`n" + $n2
Assert-Contains $main $n2 'main dart project'
$main = $main.Replace($n2, $a2)

# 3) attach tray + hook + WM_CLOSE interception after the window exists
$n3 = '  window.SetQuitOnClose(true);'
Assert-Contains $main $n3 'main set quit on close'
$main = $main.Replace($n3, $n3 + "`n" + '  CnCalendarP2::AttachMainWindow(window.GetHandle());')

# 4) cleanup before leaving wWinMain (long needle avoids matching step 2)
$n4 = '  ::CoUninitialize();' + "`n" + '  return EXIT_SUCCESS;'
$a4 = '  CnCalendarP2::Shutdown();' + "`n" + $n4
Assert-Contains $main $n4 'main shutdown point'
$main = $main.Replace($n4, $a4)

Assert-Contains $main '#include "cn_calendar_p2.h"' 'main include patched'
Assert-Contains $main 'ClaimSingleInstanceOrForward' 'main single instance patched'
Assert-Contains $main 'AttachMainWindow' 'main attach patched'
Assert-Contains $main 'CnCalendarP2::Shutdown' 'main shutdown patched'
Write-Normalized $mainPath $main

Write-Host 'P2 patch applied successfully:'
Get-Content $mainPath | Select-String -Pattern 'CnCalendarP2|cn_calendar_p2' |
  ForEach-Object { Write-Host ('  main.cpp: ' + $_.Line.Trim()) }
Get-Content $cmakePath | Select-String -Pattern 'cn_calendar_p2|shell32' |
  ForEach-Object { Write-Host ('  CMakeLists.txt: ' + $_.Line.Trim()) }
