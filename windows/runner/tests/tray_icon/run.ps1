# Compiles the real production Attention implementation and exercises its
# TrayIcon and BadgeIcon without starting the application or changing the tray.
# BaoCode is compared pixel-for-pixel with attention.cpp before the tray fix.
[CmdletBinding()]
param(
  [string]$OutputDirectory = '',
  [string]$Revision = '8419c946443ea26b231ed38dc38adcf6fd97fe04'
)
$ErrorActionPreference = 'Stop'
$test = $PSScriptRoot
$runner = (Resolve-Path (Join-Path $test '..\..')).Path
$root = (Resolve-Path (Join-Path $runner '..\..')).Path
if (-not $OutputDirectory) {
  $OutputDirectory = Join-Path $root 'build\tray-native-check'
}
if ([IO.Path]::IsPathRooted($OutputDirectory) -eq $false) {
  $OutputDirectory = Join-Path (Get-Location) $OutputDirectory
}
$work = Join-Path $OutputDirectory 'work'
New-Item -ItemType Directory -Force -Path $work | Out-Null

. (Join-Path $test 'run_helpers.ps1')

# Source and icon are local inputs; do not trust or execute downloaded content.
Copy-Item (Join-Path $test 'harness.cpp') $work -Force
Copy-Item (Join-Path $test 'harness_entry.cpp') $work -Force
Copy-Item (Join-Path $test 'harness_stubs.cpp') $work -Force
Copy-Item (Join-Path $test 'resource.rc') $work -Force
Copy-Item (Join-Path $runner 'resources\app_icon.ico') (Join-Path $work 'TRAY_TEST_ICON.ico') -Force
$log = Join-Path $OutputDirectory 'native.log'
[IO.File]::WriteAllText($log, '')
"Repository: $root" | Tee-Object -FilePath $log -Append
"Revision for BaoCode baseline: $Revision" | Tee-Object -FilePath $log -Append
$baselineSource = Join-Path $work 'attention_head.cpp'
$head = & git -C $root show "${Revision}:windows/runner/attention.cpp" 2>&1
if ($LASTEXITCODE -ne 0) { throw "Cannot read $Revision attention.cpp: $head" }
[IO.File]::WriteAllLines($baselineSource, [string[]]$head, [Text.UTF8Encoding]::new($false))

$vcvars = 'C:\Program Files\Microsoft Visual Studio\2022\Community\VC\Auxiliary\Build\vcvars64.bat'
if (-not (Test-Path -LiteralPath $vcvars)) { throw "vcvars not found: $vcvars" }
$cmd = @"
@echo off
set "PATH=%PATH%;%ProgramFiles(x86)%\Microsoft Visual Studio\Installer"
call "$vcvars" >nul
if errorlevel 1 exit /b %errorlevel%
cd /d "$work"
"$PSHOME\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File "$test\compile.ps1" -Root "$root" -Runner "$runner" -Work "$work"
"@
$driver = Join-Path $work 'compile.cmd'
[IO.File]::WriteAllText($driver, $cmd, [Text.ASCIIEncoding]::new())
& $env:ComSpec /d /c $driver 2>&1 | Tee-Object -FilePath $log -Append
if ($LASTEXITCODE -ne 0) { throw "Native test build exited with code $LASTEXITCODE" }

$abyss = Join-Path $OutputDirectory 'Abyss'
$baocode = Join-Path $OutputDirectory 'BaoCode'
& (Join-Path $work 'abyss.exe') $abyss 2>&1 | Tee-Object -FilePath $log -Append
$abyssExit = $LASTEXITCODE
"ABYSS EXIT: $abyssExit" | Tee-Object -FilePath $log -Append
& (Join-Path $work 'baocode.exe') $baocode (Join-Path $work 'baseline.exe') 2>&1 | Tee-Object -FilePath $log -Append
$baocodeExit = $LASTEXITCODE
"BAOCODE EXIT: $baocodeExit" | Tee-Object -FilePath $log -Append
if ($abyssExit -ne 0 -or $baocodeExit -ne 0) {
  throw "Native harness failed: Abyss=$abyssExit BaoCode=$baocodeExit"
}
"PASS: native tray/icon verification (exit 0)" | Tee-Object -FilePath $log -Append
