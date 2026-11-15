param([string]$Root, [string]$Runner, [string]$Work)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'run_helpers.ps1')
$flutterInclude = Join-Path $Root 'windows\flutter\ephemeral\cpp_client_wrapper\include'
$wrapper = Join-Path $Root 'windows\flutter\ephemeral\cpp_client_wrapper'
Copy-Item (Join-Path $Root 'windows\flutter\ephemeral\flutter_windows.dll') $Work -Force
foreach ($edition in @('abyss', 'baocode')) {
  $identity = Join-Path $Work "identity_$edition"
  New-Item -ItemType Directory -Force -Path $identity | Out-Null
  New-Identity (Join-Path $identity 'generated_edition_identity.h') ($edition -eq 'abyss')
}
function Compile([string]$Source, [string]$Object, [string]$Identity, [string[]]$Extra = @()) {
  $arguments = @('/nologo', '/std:c++17', '/EHsc', '/W4', '/WX', '/wd4127', '/utf-8', '/Gy', '/DNOMINMAX', '/DUNICODE', '/D_UNICODE', '/c',
    "/I$Work", "/I$Identity", "/I$Runner", "/I$Root\windows", "/I$Root\windows\flutter\ephemeral", "/I$flutterInclude", $Source, "/Fo$Object") + $Extra
  & cl @arguments
  if ($LASTEXITCODE -ne 0) { throw "cl $Source exited with code $LASTEXITCODE" }
}
& rc /nologo /i $Runner /fo (Join-Path $Work 'resource.res') (Join-Path $Work 'resource.rc')
if ($LASTEXITCODE -ne 0) { throw "rc exited with code $LASTEXITCODE" }
$identity = Join-Path $Work 'identity_abyss'
Compile (Join-Path $Work 'harness_stubs.cpp') (Join-Path $Work 'stubs.obj') $identity
Compile (Join-Path $wrapper 'standard_codec.cc') (Join-Path $Work 'codec.obj') $identity
Compile (Join-Path $wrapper 'engine_method_result.cc') (Join-Path $Work 'result.obj') $identity
foreach ($edition in @('abyss', 'baocode', 'baseline')) {
  $identity = Join-Path $Work $(if ($edition -eq 'abyss') {'identity_abyss'} else {'identity_baocode'})
  $extra = if ($edition -eq 'baseline') { @('/DTRAY_TEST_BASELINE') } else { @() }
  Compile (Join-Path $Work 'harness_entry.cpp') (Join-Path $Work "entry_$edition.obj") $identity $extra
  Compile (Join-Path $Work 'harness.cpp') (Join-Path $Work "main_$edition.obj") $identity
  & link /nologo /opt:ref /subsystem:console "/out:$Work\$edition.exe" `
    (Join-Path $Work "entry_$edition.obj") (Join-Path $Work "main_$edition.obj") `
    (Join-Path $Work 'stubs.obj') (Join-Path $Work 'codec.obj') `
    (Join-Path $Work 'result.obj') (Join-Path $Work 'resource.res') `
    (Join-Path $Root 'windows\flutter\ephemeral\flutter_windows.dll.lib') `
    user32.lib gdi32.lib shell32.lib ole32.lib winmm.lib gdiplus.lib advapi32.lib
  if ($LASTEXITCODE -ne 0) { throw "link $edition exited with code $LASTEXITCODE" }
}
