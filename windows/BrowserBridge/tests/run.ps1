param([string]$Root, [string]$Work)
$ErrorActionPreference = 'Stop'
if (-not $Root) { $Root = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..')).Path }
if (-not $Work) { $Work = Join-Path $Root 'build\browser-host-tests' }
New-Item -ItemType Directory -Force -Path $Work | Out-Null

function New-BrowserIdentity([string]$Edition, [string]$Destination) {
  $abyss = $Edition -eq 'abyss'
  $values = @{
    APP_PRODUCT_IS_ABYSS = if ($abyss) { 'true' } else { 'false' }
    APP_BROWSER_HOST = "dev.$Edition.browser"
    APP_BROWSER_HOST_TARGET = "$Edition-browser-host"
    APP_BROWSER_EXTENSION_ID = if ($abyss) { 'kecjiojfloffimkeghgongilhienkdlh' } else { 'jfjagocghaaheooicmdnhcholmgdkngk' }
    APP_BROWSER_PORT_DIRECTORY = if ($abyss) { 'Abyss-browser-bridge' } else { '' }
    APP_BROWSER_PORT_FILE = "$Edition-browser.port"
  }
  $values.APP_BROWSER_ORIGIN = "chrome-extension://$($values.APP_BROWSER_EXTENSION_ID)/"
  $text = [IO.File]::ReadAllText((Join-Path $Root 'windows\BrowserBridge\identity.h.in'))
  foreach ($key in $values.Keys) { $text = $text.Replace("@$key@", $values[$key]) }
  if ($text.Contains('@APP_')) { throw 'Not all browser identity placeholders were substituted.' }
  New-Item -ItemType Directory -Force -Path (Split-Path $Destination) | Out-Null
  [IO.File]::WriteAllText($Destination, $text, [Text.UTF8Encoding]::new($false))
}

foreach ($edition in @('abyss', 'baocode')) {
  New-BrowserIdentity $edition (Join-Path $Work "identity-$edition\generated_identity.h")
}
$vcvars = Join-Path ${env:ProgramFiles} 'Microsoft Visual Studio\2022\Community\Common7\Tools\VsDevCmd.bat'
if (-not (Test-Path $vcvars)) { throw "Visual Studio developer tools not found: $vcvars" }
$test = Join-Path $Root 'windows\BrowserBridge\tests\host_test.cpp'
$hostSource = Join-Path $Root 'windows\BrowserBridge\host.cpp'
$source = @"
@echo off
setlocal EnableDelayedExpansion
call `"$vcvars`" -arch=x64 -host_arch=x64 >nul
if errorlevel 1 exit /b 1
for %%E in (abyss baocode) do (
  cl /nologo /std:c++17 /EHsc /W4 /WX /wd4505 /wd4127 /utf-8 /DUNICODE /D_UNICODE /DNOMINMAX /DWIN32_LEAN_AND_MEAN /I"$Work\identity-%%E" "$test" /Fe:"$Work\%%E-test.exe" /Fo:"$Work\%%E-test.obj" /link advapi32.lib ws2_32.lib || exit /b 1
  cl /nologo /std:c++17 /EHsc /W4 /WX /wd4505 /wd4127 /utf-8 /DUNICODE /D_UNICODE /DNOMINMAX /DWIN32_LEAN_AND_MEAN /I"$Work\identity-%%E" "$hostSource" /Fe:"$Work\%%E-browser-host.exe" /Fo:"$Work\%%E-host.obj" /link advapi32.lib ws2_32.lib || exit /b 1
  mkdir "$Work\run-%%E" 2>nul
  pushd "$Work\run-%%E"
  "$Work\%%E-test.exe"
  set test_error=!errorlevel!
  popd
  if not !test_error! == 0 exit /b !test_error!
)
"@
$batch = Join-Path $Work 'compile-and-run.cmd'
[IO.File]::WriteAllText($batch, $source, [Text.ASCIIEncoding]::new())
& cmd.exe /d /c $batch
if ($LASTEXITCODE -ne 0) { throw "Native browser host tests failed: $LASTEXITCODE" }
foreach ($edition in @('abyss', 'baocode')) {
  foreach ($name in @("$edition-test.exe", "$edition-browser-host.exe")) {
    if (-not (Test-Path (Join-Path $Work $name))) { throw "Missing compiled output: $name" }
  }
  $isolated = Join-Path $Work ("check-$edition-" + [Guid]::NewGuid().ToString('N'))
  New-Item -ItemType Directory -Path $isolated | Out-Null
  Push-Location $isolated
  try {
    & (Join-Path $Work "$edition-test.exe")
    if ($LASTEXITCODE -ne 0) { throw "$edition host assertions failed: $LASTEXITCODE" }
  } finally { Pop-Location }
}
