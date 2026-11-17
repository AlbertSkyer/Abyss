; The Windows installer, compiled by tool/build_windows.dart.
;
; Required /D defines:
;   BundleDir  the Release bundle to pack (the folder holding its executable)
;   AppVersion the version pubspec.yaml carries, as it writes it (1.0.0+1)
;   OutDir     where to write the installer (build/installers)
;   AppEdition Abyss or BaoCode (the default)
;
; Output: <product>-<version>-setup.exe (-setup-arm64.exe for Arm)

#ifndef BundleDir
  #error BundleDir is not defined: pass /DBundleDir=<release bundle folder>
#endif
#ifndef AppVersion
  #error AppVersion is not defined: pass /DAppVersion=<version from pubspec.yaml>
#endif
#ifndef OutDir
  #error OutDir is not defined: pass /DOutDir=<folder for the installer>
#endif

#ifndef AppEdition
  #define AppEdition "BaoCode"
#endif
#if AppEdition == "Abyss"
  #define ProductName "Abyss"
  #define BinaryName "Abyss.exe"
  #define WerModule "abyss_wer.dll"
  #define AppGuid "{{0bf422b7-e758-4d4a-a649-31c8a52f589c}"
  #define UrlScheme "abyss"
  #define CliFlag "--abyss-cli"
  #define AgentFlag "--abyss-agent"
  #define LinkFlag "--abyss-link"
  #define BundleBrowser 1
  #define BrowserHostName "dev.abyss.browser"
  #define BrowserHostBinary "abyss-browser-host.exe"
  #define BrowserHostManifest "dev.abyss.browser.json"
#elif AppEdition == "BaoCode"
  #define ProductName "BaoCode"
  #define BinaryName "baocode.exe"
  #define WerModule "baocode_wer.dll"
  #define AppGuid "{{6fdd732b-95c6-4c37-af6f-ff574358deb5}"
  #define UrlScheme "baocode"
  #define CliFlag "--baocode-cli"
  #define AgentFlag "--baocode-agent"
  #define LinkFlag "--baocode-link"
  #define BundleBrowser 1
  #define BrowserHostName "dev.baocode.browser"
  #define BrowserHostBinary "baocode-browser-host.exe"
  #define BrowserHostManifest "dev.baocode.browser.json"
#else
  #error AppEdition must be Abyss or BaoCode
#endif

; The channel build's (tool/build_windows.dart --channel): "-channel", after
; the installer's name. The same app either way, installed over the other.
#ifndef Edition
  #define Edition ""
#endif

; The processor the bundle was built for (tool/build_windows.dart passes
; it): x64, or arm64, whose installer's name says so ("-arm64", before the
; edition's). The same app either way: one installs over the other.
#ifndef Arch
  #define Arch "x64"
#endif
#if Arch == "arm64"
  #define ArchSuffix "-arm64"
#else
  #define ArchSuffix ""
#endif

; The part of the version Windows records, without the build number pubspec
; adds after "+".
#define VersionNumber Copy(AppVersion, 1, Pos("+", AppVersion) - 1)
#if Pos("+", AppVersion) == 0
  #undef VersionNumber
  #define VersionNumber AppVersion
#endif

[Setup]
; Base of the identity Windows uses for the installed app. It must not change
; between versions, or an upgrade installs beside the old one instead of over
; it.
AppId={#AppGuid}
AppName={#ProductName}
AppVersion={#VersionNumber}
AppPublisher={#ProductName}
AppVerName={#ProductName} {#VersionNumber}
DefaultDirName={autopf}\{#ProductName}
DefaultGroupName={#ProductName}
UninstallDisplayName={#ProductName}
UninstallDisplayIcon={app}\{#BinaryName}
OutputBaseFilename={#ProductName}-{#VersionNumber}-setup{#ArchSuffix}{#Edition}
OutputDir={#OutDir}
; What Explorer shows for the installer itself. Windows wants four numbers,
; where pubspec's version has three.
VersionInfoVersion={#VersionNumber}.0
Compression=lzma2/max
SolidCompression=yes
WizardStyle=modern
; The app is 64-bit only: x64 (which Windows on Arm runs too, emulated),
; or arm64.
#if Arch == "arm64"
ArchitecturesAllowed=arm64
ArchitecturesInstallIn64BitMode=arm64
#else
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
#endif
; Per user by default ({autopf} is then %LOCALAPPDATA%\Programs): neither
; the install nor the app's updates ask for elevation, which a machine may
; not grant (no admin; UAC set to elevate signed programs only, and Setup is
; not signed) or show behind other windows. For all users (Program Files,
; elevated) is the dialog's other choice; an update keeps the install mode
; there is (UsePreviousPrivileges, and lib/update/installer_io.dart passes
; it).
PrivilegesRequired=lowest
PrivilegesRequiredOverridesAllowed=dialog
DisableProgramGroupPage=yes
; A running copy of this edition is asked to close (it quits on
; WM_ENDSESSION, see windows/runner/flutter_window.cpp), and ended if it
; does not. Only this edition's executable is eligible to be closed.
CloseApplications=force
AppMutex={#ProductName}.Setup
; Always a log (%TEMP%\Setup Log <date> #<n>.txt, or where /LOG= says, as
; an update the app runs does): a silent install that fails says why only
; there.
SetupLogging=yes

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; \
  GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked
Name: "addtopath"; Description: "Add {#ProductName} to the PATH"; \
  GroupDescription: "Other:"; Flags: unchecked
Name: "contextmenu"; \
  Description: "Add ""Open with {#ProductName}"" and ""Open with Fast Ide"" to Explorer's context menu"; \
  GroupDescription: "Other:"

[Files]
; The whole bundle: the edition's executable, engine and plugin DLLs, data\
; (the AOT app.so and flutter_assets), remote\ (VERSION and servers.json),
; openssh\, and the edition's own browser host and extension. Each edition
; stops only its own host before replacing it.
Source: "{#BundleDir}\*"; Excludes: "\{#BrowserHostBinary}"; \
  DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs
Source: "{#BundleDir}\{#BrowserHostBinary}"; DestDir: "{app}"; \
  Flags: ignoreversion; BeforeInstall: ReplaceBrowserHost

[InstallDelete]
; A host ReplaceBrowserHost moved out of the way, at an install before.
Type: files; Name: "{app}\{#BrowserHostBinary}.*.old"

[UninstallDelete]
Type: files; Name: "{app}\{#BrowserHostBinary}.*.old"

[Icons]
Name: "{group}\{#ProductName}"; Filename: "{app}\{#BinaryName}"
Name: "{group}\{cm:UninstallProgram,{#ProductName}}"; Filename: "{uninstallexe}"
Name: "{autodesktop}\{#ProductName}"; Filename: "{app}\{#BinaryName}"; Tasks: desktopicon

[Registry]
; Only when asked for. Which hive follows the install mode: a per-machine
; install writes the machine's PATH (HKLM), a per-user one the user's (HKCU).
; Writing HKCU while installing as admin would put the entry in whichever
; account elevated, which is not necessarily the one that runs the app.
Root: HKLM; Subkey: "SYSTEM\CurrentControlSet\Control\Session Manager\Environment"; \
  ValueType: expandsz; ValueName: "Path"; ValueData: "{olddata};{app}"; \
  Tasks: addtopath; Check: IsAdminInstallMode and NeedsAddPath(ExpandConstant('{app}'), True)
Root: HKCU; Subkey: "Environment"; ValueType: expandsz; ValueName: "Path"; \
  ValueData: "{olddata};{app}"; Tasks: addtopath; \
  Check: (not IsAdminInstallMode) and NeedsAddPath(ExpandConstant('{app}'), False)

; The edition's WER module listed for Windows Error Reporting, as the app
; lists it for the user who runs it (hang_watchdog.cpp's
; RegisterFastFailModule): written here so that uninstalling removes it.
; The user's own, so a per-user install's only.
Root: HKCU; Subkey: "Software\Microsoft\Windows\Windows Error Reporting\RuntimeExceptionHelperModules"; \
  ValueType: dword; ValueName: "{app}\{#WerModule}"; ValueData: 0; \
  Flags: uninsdeletevalue; Check: not IsAdminInstallMode

; Explorer's context menu, on a file, a folder and a folder's background,
; each in a new window: Open with BaoCode, a new agent in a narrow window of
; its own (a file in its composer; see AppWindows.openAgent), and Open with
; Fast Ide, as `code -n` opens it (the path its own working folder: it is
; absolute). HKA is the install mode's hive (HKLM per machine, HKCU per
; user). Windows 11 lists them under "Show more options". Unticked on a
; reinstall, they go. Settings → General writes the same keys under HKCU
; (lib/platform/context_menu_io.dart), for the user alone.
Root: HKA; Subkey: "Software\Classes\*\shell\{#ProductName}"; ValueType: string; \
  ValueName: ""; ValueData: "{code:MenuLabel|{#ProductName}}"; Tasks: contextmenu; \
  Flags: uninsdeletekey
Root: HKA; Subkey: "Software\Classes\*\shell\{#ProductName}"; ValueType: string; \
  ValueName: "Icon"; ValueData: """{app}\{#BinaryName}"""; Tasks: contextmenu
Root: HKA; Subkey: "Software\Classes\*\shell\{#ProductName}\command"; \
  ValueType: string; ValueName: ""; \
  ValueData: """{app}\{#BinaryName}"" {#AgentFlag} ""%1"""; Tasks: contextmenu
Root: HKA; Subkey: "Software\Classes\Directory\shell\{#ProductName}"; \
  ValueType: string; ValueName: ""; ValueData: "{code:MenuLabel|{#ProductName}}"; \
  Tasks: contextmenu; Flags: uninsdeletekey
Root: HKA; Subkey: "Software\Classes\Directory\shell\{#ProductName}"; \
  ValueType: string; ValueName: "Icon"; ValueData: """{app}\{#BinaryName}"""; \
  Tasks: contextmenu
Root: HKA; Subkey: "Software\Classes\Directory\shell\{#ProductName}\command"; \
  ValueType: string; ValueName: ""; \
  ValueData: """{app}\{#BinaryName}"" {#AgentFlag} ""%V"""; Tasks: contextmenu
Root: HKA; Subkey: "Software\Classes\Directory\Background\shell\{#ProductName}"; \
  ValueType: string; ValueName: ""; ValueData: "{code:MenuLabel|{#ProductName}}"; \
  Tasks: contextmenu; Flags: uninsdeletekey
Root: HKA; Subkey: "Software\Classes\Directory\Background\shell\{#ProductName}"; \
  ValueType: string; ValueName: "Icon"; ValueData: """{app}\{#BinaryName}"""; \
  Tasks: contextmenu
Root: HKA; Subkey: "Software\Classes\Directory\Background\shell\{#ProductName}\command"; \
  ValueType: string; ValueName: ""; \
  ValueData: """{app}\{#BinaryName}"" {#AgentFlag} ""%V"""; Tasks: contextmenu
Root: HKA; Subkey: "Software\Classes\*\shell\{#ProductName}FastIde"; \
  ValueType: string; ValueName: ""; ValueData: "{code:MenuLabel|Fast Ide}"; \
  Tasks: contextmenu; Flags: uninsdeletekey
Root: HKA; Subkey: "Software\Classes\*\shell\{#ProductName}FastIde"; \
  ValueType: string; ValueName: "Icon"; ValueData: """{app}\{#BinaryName}"""; \
  Tasks: contextmenu
Root: HKA; Subkey: "Software\Classes\*\shell\{#ProductName}FastIde\command"; \
  ValueType: string; ValueName: ""; \
  ValueData: """{app}\{#BinaryName}"" {#CliFlag} ""%1"" -n ""%1"""; \
  Tasks: contextmenu
Root: HKA; Subkey: "Software\Classes\Directory\shell\{#ProductName}FastIde"; \
  ValueType: string; ValueName: ""; ValueData: "{code:MenuLabel|Fast Ide}"; \
  Tasks: contextmenu; Flags: uninsdeletekey
Root: HKA; Subkey: "Software\Classes\Directory\shell\{#ProductName}FastIde"; \
  ValueType: string; ValueName: "Icon"; ValueData: """{app}\{#BinaryName}"""; \
  Tasks: contextmenu
Root: HKA; Subkey: "Software\Classes\Directory\shell\{#ProductName}FastIde\command"; \
  ValueType: string; ValueName: ""; \
  ValueData: """{app}\{#BinaryName}"" {#CliFlag} ""%V"" -n ""%V"""; \
  Tasks: contextmenu
Root: HKA; Subkey: "Software\Classes\Directory\Background\shell\{#ProductName}FastIde"; \
  ValueType: string; ValueName: ""; ValueData: "{code:MenuLabel|Fast Ide}"; \
  Tasks: contextmenu; Flags: uninsdeletekey
Root: HKA; Subkey: "Software\Classes\Directory\Background\shell\{#ProductName}FastIde"; \
  ValueType: string; ValueName: "Icon"; ValueData: """{app}\{#BinaryName}"""; \
  Tasks: contextmenu
Root: HKA; Subkey: "Software\Classes\Directory\Background\shell\{#ProductName}FastIde\command"; \
  ValueType: string; ValueName: ""; \
  ValueData: """{app}\{#BinaryName}"" {#CliFlag} ""%V"" -n ""%V"""; \
  Tasks: contextmenu
; The product's own URL scheme: one-click provider imports and opening a
; file in the IDE. Abyss never replaces BaoCode's scheme registration.
Root: HKA; Subkey: "Software\Classes\{#UrlScheme}"; ValueType: string; \
  ValueName: ""; ValueData: "URL:{#ProductName}"; Flags: uninsdeletekey
Root: HKA; Subkey: "Software\Classes\{#UrlScheme}"; ValueType: string; \
  ValueName: "URL Protocol"; ValueData: ""
Root: HKA; Subkey: "Software\Classes\{#UrlScheme}\DefaultIcon"; ValueType: string; \
  ValueName: ""; ValueData: """{app}\{#BinaryName}"",0"
Root: HKA; Subkey: "Software\Classes\{#UrlScheme}\shell\open\command"; \
  ValueType: string; ValueName: ""; \
  ValueData: """{app}\{#BinaryName}"" {#LinkFlag} ""%1"""
; The browsers' native messaging host for this edition's extension, always
; (windows/BrowserBridge): a browser finds the edition's manifest beside its
; executable by its own leaf key, and the manifest names the host beside it.
; The other edition's host name and keys are never written or removed.
; Chrome's key is also the one Brave, Vivaldi and other Chromium browsers
; read; Edge and Chromium read their own. Parent keys go at uninstall only
; when nothing else is left in them (another host or no installed browser).
Root: HKA; Subkey: "Software\Google"; ValueType: none; \
  Flags: uninsdeletekeyifempty
Root: HKA; Subkey: "Software\Google\Chrome"; ValueType: none; \
  Flags: uninsdeletekeyifempty
Root: HKA; Subkey: "Software\Google\Chrome\NativeMessagingHosts"; \
  ValueType: none; Flags: uninsdeletekeyifempty
Root: HKA; Subkey: "Software\Google\Chrome\NativeMessagingHosts\{#BrowserHostName}"; \
  ValueType: string; ValueName: ""; \
  ValueData: "{app}\{#BrowserHostManifest}"; Flags: uninsdeletekey
Root: HKA; Subkey: "Software\Microsoft\Edge"; ValueType: none; \
  Flags: uninsdeletekeyifempty
Root: HKA; Subkey: "Software\Microsoft\Edge\NativeMessagingHosts"; \
  ValueType: none; Flags: uninsdeletekeyifempty
Root: HKA; Subkey: "Software\Microsoft\Edge\NativeMessagingHosts\{#BrowserHostName}"; \
  ValueType: string; ValueName: ""; \
  ValueData: "{app}\{#BrowserHostManifest}"; Flags: uninsdeletekey
Root: HKA; Subkey: "Software\Chromium"; ValueType: none; \
  Flags: uninsdeletekeyifempty
Root: HKA; Subkey: "Software\Chromium\NativeMessagingHosts"; \
  ValueType: none; Flags: uninsdeletekeyifempty
Root: HKA; Subkey: "Software\Chromium\NativeMessagingHosts\{#BrowserHostName}"; \
  ValueType: string; ValueName: ""; \
  ValueData: "{app}\{#BrowserHostManifest}"; Flags: uninsdeletekey
; Unticked: what an earlier install added goes.
Root: HKA; Subkey: "Software\Classes\*\shell\{#ProductName}"; ValueType: none; \
  Tasks: not contextmenu; Flags: deletekey
Root: HKA; Subkey: "Software\Classes\Directory\shell\{#ProductName}"; ValueType: none; \
  Tasks: not contextmenu; Flags: deletekey
Root: HKA; Subkey: "Software\Classes\Directory\Background\shell\{#ProductName}"; \
  ValueType: none; Tasks: not contextmenu; Flags: deletekey
Root: HKA; Subkey: "Software\Classes\*\shell\{#ProductName}FastIde"; ValueType: none; \
  Tasks: not contextmenu; Flags: deletekey
Root: HKA; Subkey: "Software\Classes\Directory\shell\{#ProductName}FastIde"; \
  ValueType: none; Tasks: not contextmenu; Flags: deletekey
Root: HKA; Subkey: "Software\Classes\Directory\Background\shell\{#ProductName}FastIde"; \
  ValueType: none; Tasks: not contextmenu; Flags: deletekey

[Run]
Filename: "{app}\{#BinaryName}"; Description: "{cm:LaunchProgram,{#ProductName}}"; \
  Flags: nowait postinstall skipifsilent
; An update the app ran (lib/update/installer_io.dart) is silent, which
; skips the entry above: /RELAUNCH opens the app again once it is in place,
; as the user who ran it rather than the administrator Setup elevated to.
Filename: "{app}\{#BinaryName}"; Flags: nowait runasoriginaluser; \
  Check: RelaunchRequested

[Code]
const
  SYNCHRONIZE = $00100000;
  WaitPidTimeout = 120000;

function OpenProcess(dwDesiredAccess: DWORD; bInheritHandle: BOOL;
  dwProcessId: DWORD): THandle;
  external 'OpenProcess@kernel32.dll stdcall';
function WaitForSingleObject(hHandle: THandle; dwMilliseconds: DWORD): DWORD;
  external 'WaitForSingleObject@kernel32.dll stdcall';
function CloseHandle(hObject: THandle): BOOL;
  external 'CloseHandle@kernel32.dll stdcall';

// An update the app runs (lib/update/installer_io.dart) starts Setup as the
// app quits, with /WAITPID=<the app's process>, so the elevation it asks
// for comes up in front of the app: it waits here (two minutes at most) for
// the app to be gone before installing over it. One that does not go is
// closed by CloseApplications=force.
function InitializeSetup: Boolean;
var
  Pid: Integer;
  App: THandle;
begin
  Result := True;
  Pid := StrToIntDef(ExpandConstant('{param:WAITPID|0}'), 0);
  if Pid <= 0 then
    Exit;
  App := OpenProcess(SYNCHRONIZE, False, Pid);
  if App = 0 then
  begin
    Log(Format('Process %d is gone already', [Pid]));
    Exit;
  end;
  Log(Format('Waiting for process %d to quit', [Pid]));
  if WaitForSingleObject(App, WaitPidTimeout) <> 0 then
    Log(Format('Process %d is still running', [Pid]));
  CloseHandle(App);
end;

// The browser extension's host has no window, so CloseApplications does not
// close it. End it before replacing or removing it; the extension reconnects
// on its own (each minute) to the host installed.
#if AppEdition == "BaoCode"
// BaoCode keeps its existing image-name behavior. In particular, an Abyss
// install never calls taskkill by either product's image name.
procedure EndBrowserHost;
var
  Code: Integer;
begin
  if Exec(ExpandConstant('{sys}\taskkill.exe'),
    '/F /IM {#BrowserHostBinary}', '', SW_HIDE,
    ewWaitUntilTerminated, Code) then
    Log(Format('taskkill {#BrowserHostBinary}: %d', [Code]));
end;
#else
function SetEnvironmentVariable(Name: String; Value: String): BOOL;
  external 'SetEnvironmentVariableW@kernel32.dll stdcall';

// This script is fixed ASCII, written by this installer, never downloaded.
// The path travels only through the environment, so quotes, ampersands and
// other shell characters in {app} are data rather than PowerShell syntax.
// Name restricts the CIM query, but ExecutablePath alone decides which PID
// may be stopped: a same-named host elsewhere, and BaoCode's host, do not
// match. The comparison ignores case, as Windows paths do; it has no prefix,
// wildcard or substring matching.
const
  BrowserHostStopScript =
    '$ErrorActionPreference = ''Stop''' + #13#10 +
    '$target = $env:ABYSS_BROWSER_HOST_TARGET' + #13#10 +
    'if ([string]::IsNullOrEmpty($target)) {' + #13#10 +
    '  throw ''ABYSS_BROWSER_HOST_TARGET is empty''' + #13#10 +
    '}' + #13#10 +
    'Get-CimInstance -ClassName Win32_Process -Filter "Name = ''{#BrowserHostBinary}''" |' + #13#10 +
    '  Where-Object {' + #13#10 +
    '    $_.ExecutablePath -and' + #13#10 +
    '    [string]::Equals($_.ExecutablePath, $target, [System.StringComparison]::OrdinalIgnoreCase)' + #13#10 +
    '  } | ForEach-Object {' + #13#10 +
    '    Stop-Process -Id $_.ProcessId -Force -ErrorAction Stop' + #13#10 +
    '  }' + #13#10;

procedure EndBrowserHost;
var
  Code: Integer;
  Script: String;
begin
  Script := ExpandConstant('{tmp}\abyss-browser-host-stop.ps1');
  if not SaveStringToFile(Script, BrowserHostStopScript, False) then
  begin
    Log('Could not write the Abyss browser host stop script');
    Exit;
  end;
  try
    if not SetEnvironmentVariable('ABYSS_BROWSER_HOST_TARGET',
      ExpandConstant('{app}\{#BrowserHostBinary}')) then
    begin
      Log('Could not set ABYSS_BROWSER_HOST_TARGET');
      Exit;
    end;
    if Exec(ExpandConstant(
        '{sys}\WindowsPowerShell\v1.0\powershell.exe'),
      '-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "' +
        Script + '"', '', SW_HIDE, ewWaitUntilTerminated, Code) then
      Log(Format('Abyss browser host path-matched stop: %d', [Code]))
    else
      Log('Could not start PowerShell to stop the Abyss browser host');
  finally
    SetEnvironmentVariable('ABYSS_BROWSER_HOST_TARGET', '');
    DeleteFile(Script);
  end;
end;
#endif

// Right before the host is replaced, ended again: the extension connects
// each minute, and the install takes long enough for it to have started the
// host anew since PrepareToInstall, whose file then could not be replaced.
// Started again in between, or not quite gone yet, it is moved out of the
// way, as Windows lets a running program's file be; [InstallDelete] removes
// it at the next install.
procedure ReplaceBrowserHost;
var
  Host: String;
  Old: String;
begin
  EndBrowserHost;
  Host := ExpandConstant('{app}\{#BrowserHostBinary}');
  if (not FileExists(Host)) or DeleteFile(Host) then
    Exit;
  Old := Host + '.' + GetDateTimeString('yyyymmddhhnnsszzz', #0, #0) + '.old';
  if RenameFile(Host, Old) then
    Log(Format('%s is in use: moved to %s', [Host, Old]))
  else
    Log(Format('%s is in use, and could not be moved', [Host]));
end;

function PrepareToInstall(var NeedsRestart: Boolean): String;
begin
  Result := '';
  EndBrowserHost;
end;

procedure CurUninstallStepChanged(CurUninstallStep: TUninstallStep);
begin
  if CurUninstallStep = usUninstall then
    EndBrowserHost;
end;

// Whether the command line asks for the app to be opened after a silent
// install (/RELAUNCH, an update's; see [Run]). Not silent, the finish
// page's checkbox opens it.
function RelaunchRequested: Boolean;
var
  I: Integer;
begin
  Result := False;
  if not WizardSilent then
    Exit;
  for I := 1 to ParamCount do
    if CompareText(ParamStr(I), '/RELAUNCH') = 0 then
    begin
      Result := True;
      Exit;
    end;
end;

// The context menu's labels (see [Registry]): "Open with BaoCode", in
// Chinese where Windows is. Written as code points, so the script's encoding
// does not matter.
function MenuLabel(Param: String): String;
begin
  if (GetUILanguage and $3FF) = $04 then
    Result := #$7528 + ' ' + Param + ' ' + #$6253#$5F00
  else
    Result := 'Open with ' + Param;
end;

// Whether {app} is already on the PATH the install will write, so a reinstall
// does not append it a second time. Machine reads the machine's PATH, user the
// user's, matching [Registry] above.
function NeedsAddPath(Param: string; Machine: Boolean): Boolean;
var
  Path: String;
  Subkey: String;
  RootKey: Integer;
begin
  if Machine then
  begin
    RootKey := HKEY_LOCAL_MACHINE;
    Subkey := 'SYSTEM\CurrentControlSet\Control\Session Manager\Environment';
  end
  else
  begin
    RootKey := HKEY_CURRENT_USER;
    Subkey := 'Environment';
  end;

  if not RegQueryStringValue(RootKey, Subkey, 'Path', Path) then
  begin
    Result := True;
    Exit;
  end;
  Result := Pos(';' + Uppercase(Param) + ';', ';' + Uppercase(Path) + ';') = 0;
end;
