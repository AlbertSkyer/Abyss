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
