import 'dart:convert';
import 'dart:io';

/// Establishes the private directory before a Windows bridge token is written.
/// Paths travel through the environment, never interpolated into shell code.
abstract final class BrowserEndpoint {
  static Future<void> secureDirectory(String path) async {
    final result = await Process.run(
      'powershell.exe',
      ['-NoProfile', '-NonInteractive', '-Command', secureScript],
      environment: {'ABYSS_BROWSER_ENDPOINT': path},
      includeParentEnvironment: true,
    );
    if (result.exitCode != 0) {
      throw const FileSystemException(
        'Could not establish a private browser endpoint directory',
      );
    }
  }

  /// Fix the files themselves: a directory's owner is not inherited by files
  /// created with an elevated token (whose default owner can be Administrators).
  /// Called before the temporary port file is published to the native host.
  static Future<void> secureFiles(List<String> paths) async {
    final result = await Process.run(
      'powershell.exe',
      ['-NoProfile', '-NonInteractive', '-Command', secureFilesScript],
      environment: {'ABYSS_BROWSER_ENDPOINT_FILES': jsonEncode(paths)},
      includeParentEnvironment: true,
    );
    if (result.exitCode != 0) {
      throw const FileSystemException(
        'Could not secure browser endpoint files',
      );
    }
  }

  static const secureFilesScript = r'''
$ErrorActionPreference = 'Stop'
$user = [Security.Principal.WindowsIdentity]::GetCurrent().User
$allowed = @($user.Value, 'S-1-5-18', 'S-1-5-32-544')
$paths = ConvertFrom-Json -InputObject $env:ABYSS_BROWSER_ENDPOINT_FILES
foreach ($path in $paths) {
  $file = Get-Item -LiteralPath $path -Force
  if ($file.PSIsContainer -or ($file.Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw 'Unsafe endpoint file' }
  $parent = $file.Directory
  while ($null -ne $parent) {
    if ($parent.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Reparse endpoint ancestor' }
    $parent = $parent.Parent
  }
  $security = New-Object Security.AccessControl.FileSecurity
  $security.SetOwner($user)
  $security.SetAccessRuleProtection($true, $false)
  foreach ($sid in $allowed) {
    $security.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new(
      [Security.Principal.SecurityIdentifier]::new($sid), 'FullControl', 'Allow'))
  }
  $file.SetAccessControl($security)
  $actual = $file.GetAccessControl([Security.AccessControl.AccessControlSections]::Owner -bor [Security.AccessControl.AccessControlSections]::Access)
  if (-not $actual.GetOwner([Security.Principal.SecurityIdentifier]).Equals($user) -or -not $actual.AreAccessRulesProtected) { throw 'Endpoint security verification failed' }
  foreach ($rule in $actual.GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier])) {
    if ($rule.AccessControlType -eq 'Allow' -and $rule.IdentityReference.Value -notin $allowed) { throw 'Unexpected endpoint access' }
  }
}
''';

  static const secureScript = r'''
$ErrorActionPreference = 'Stop'
$path = $env:ABYSS_BROWSER_ENDPOINT
if ([string]::IsNullOrWhiteSpace($path)) { throw 'Missing endpoint path' }
$parent = [IO.DirectoryInfo]::new([IO.Path]::GetDirectoryName($path))
while ($null -ne $parent) {
  if ($parent.Exists -and ($parent.Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw 'Reparse endpoint ancestor' }
  $parent = $parent.Parent
}
$user = [Security.Principal.WindowsIdentity]::GetCurrent().User
if (Test-Path -LiteralPath $path) {
  $item = Get-Item -LiteralPath $path -Force
  if (-not $item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw 'Unsafe endpoint directory' }
  $owner = (Get-Acl -LiteralPath $path).GetOwner([Security.Principal.SecurityIdentifier])
  if (-not $owner.Equals($user)) { throw 'Unexpected endpoint owner' }
}
$acl = New-Object Security.AccessControl.DirectorySecurity
$acl.SetOwner($user)
$acl.SetAccessRuleProtection($true, $false)
foreach ($sid in @($user, [Security.Principal.SecurityIdentifier]::new('S-1-5-18'), [Security.Principal.SecurityIdentifier]::new('S-1-5-32-544'))) {
  $rule = [Security.AccessControl.FileSystemAccessRule]::new($sid, 'FullControl', 'ContainerInherit,ObjectInherit', 'None', 'Allow')
  $acl.AddAccessRule($rule)
}
$directory = [IO.DirectoryInfo]::new($path)
if ($directory.Exists) { $directory.SetAccessControl($acl) } else { $directory.Create($acl) }
''';
}
