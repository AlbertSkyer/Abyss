param([Parameter(Mandatory=$true)][string]$Root)
$ErrorActionPreference='Stop'
# Optional elevated acceptance. Run only in a new isolated directory; never on
# the running app's endpoint. No token contents or secret values are printed.
if(Test-Path -LiteralPath $Root){throw 'Use a new isolated directory'}
New-Item -ItemType Directory -Path $Root | Out-Null
$source=Get-Content -LiteralPath (Join-Path $PSScriptRoot '..\..\..\lib\browser\browser_endpoint.dart') -Raw
$match=[regex]::Match($source,"static const secureFilesScript = r'''([\s\S]*?)''';")
if(-not $match.Success){throw 'Endpoint security script not found'}
$user=[Security.Principal.WindowsIdentity]::GetCurrent().User
$principal=[Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent())
$file=Join-Path $Root 'abyss-browser.port.staging'
$lock=Join-Path $Root 'abyss-browser.lock'
[IO.File]::WriteAllText($file,'synthetic fixture only')
[IO.File]::WriteAllText($lock,'')
$before=(Get-Acl -LiteralPath $file).GetOwner([Security.Principal.SecurityIdentifier])
$env:ABYSS_BROWSER_ENDPOINT_FILES=ConvertTo-Json -Compress -InputObject @($file,$lock)
& ([ScriptBlock]::Create($match.Groups[1].Value))
$published=Join-Path $Root 'abyss-browser.port'
[IO.File]::Move($file,$published)
foreach($path in @($published,$lock)){
 $acl=Get-Acl -LiteralPath $path
 if(-not $acl.GetOwner([Security.Principal.SecurityIdentifier]).Equals($user)){throw 'Owner normalization failed'}
 if(-not $acl.AreAccessRulesProtected){throw 'DACL not protected'}
}
[pscustomobject]@{Elevated=$principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator);OriginalOwnerWasAdministrators=($before.Value -eq 'S-1-5-32-544');PublishedOwnerIsCurrentUser=$true;LockOwnerIsCurrentUser=$true} | ConvertTo-Json
Remove-Item Env:ABYSS_BROWSER_ENDPOINT_FILES
