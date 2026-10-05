# Offline checks: no installation, registry, services or environment are changed.
$ErrorActionPreference = 'Stop'
$ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot 'RevitToolkit.ps1'), [ref]$null, [ref]$null)
foreach ($name in @('Get-UiText', 'Get-LicenseLocalhostCleanup', 'Test-AutodeskDownloadUri', 'Get-AutodeskComponentLinks', 'Assert-AutodeskInstaller', 'Invoke-LicenseLocalCleanup', 'Invoke-LicenseLoginReset', 'Invoke-AutodeskComponentInstall')) {
    $f=$ast.Find({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name},$true)
    . ([scriptblock]::Create($f.Extent.Text))
}
$result = Get-LicenseLocalhostCleanup '27000@localhost;2080@real-server;C:\licenses\network.lic;@127.0.0.1'
if (-not $result.Changed -or $result.Value -ne '2080@real-server;C:\licenses\network.lic') { throw 'Other license addresses were not preserved' }
$original='2080@localhost.company; 2080@real-server'
$result = Get-LicenseLocalhostCleanup $original
if ($result.Changed -or $result.Value -ne $original) { throw 'Non-localhost value changed' }
if ((Get-LicenseLocalhostCleanup '@[::1],localhost').Value) { throw 'Loopback entries remain' }
foreach ($url in @('https://download.autodesk.com/test.exe', 'https://www.autodesk.com/test.zip')) {
    if (-not (Test-AutodeskDownloadUri $url)) { throw 'Official URI rejected' }
}
foreach ($url in @('http://download.autodesk.com/test.exe','https://autodesk.com.evil.com/test.exe','https://evilautodesk.com/test.exe','https://user@download.autodesk.com/test.exe','file:///C:/test.exe')) {
    if (Test-AutodeskDownloadUri $url) { throw 'Unsafe URI accepted' }
}
$html='<a href="https://download.autodesk.com/AdskLicensingInstaller-win-17.0.zip">Windows</a><a href="https://download.autodesk.com/AdskLicensingInstaller-linux-17.0.tar.gz">Linux</a><a href="https://evil.com/AdskLicensingInstaller-win.zip">Other</a>'
$links=@(Get-AutodeskComponentLinks $html Licensing)
if ($links.Count -ne 1 -or $links[0] -notlike '*-win-17.0.zip') { throw 'Windows component resolution failed' }
$identity='https:\/\/download.autodesk.com\/AdskIdentityManager-1.0.exe'
if (@(Get-AutodeskComponentLinks $identity Identity).Count -ne 1) { throw 'JSON URL decoding failed' }
$Script:SignatureStatus='Valid'; $Script:Signer='CN=Autodesk, O="Autodesk, Inc.", C=US'
function Get-AuthenticodeSignature { return [pscustomobject]@{Status=$Script:SignatureStatus; SignerCertificate=[pscustomobject]@{Subject=$Script:Signer}} }
Assert-AutodeskInstaller 'dummy.exe'
$Script:Signer='CN=Other, O=Other Inc., C=US'
$rejected=$false
try { Assert-AutodeskInstaller 'dummy.exe' } catch { $rejected=$true }
if (-not $rejected) { throw 'Other publisher accepted' }
$Script:Signer='O=Autodesk, Inc., C=US'; $Script:SignatureStatus='NotSigned'
$rejected=$false
try { Assert-AutodeskInstaller 'dummy.exe' } catch { $rejected=$true }
if (-not $rejected) { throw 'Unsigned installer accepted' }
function Write-Warn {}
function Test-DryRun { return $true }
function Assert-Admin { throw 'Unexpected admin check after dry-run guard' }
function New-LicenseRepairBackup { throw 'Unexpected backup mutation' }
function Get-AutodeskComponentInstaller { throw 'Unexpected network request' }
function Start-Process { throw 'Unexpected installer execution' }
Invoke-LicenseLocalCleanup
Invoke-LicenseLoginReset
Invoke-AutodeskComponentInstall Licensing -Reinstall
Invoke-AutodeskComponentInstall Identity
function Test-DryRun { return $false }
function Assert-Admin { return $true }
function Confirm-Action { return $true }
function Get-AutodeskComponentInstaller { return 'signed-test-installer.exe' }
function Write-Ok {}
$Script:LaunchCount=0; $Script:InstallerExit=1603
function Start-Process { $Script:LaunchCount++; return [pscustomobject]@{ ExitCode=$Script:InstallerExit } }
$Script:Signer='O=Autodesk, Inc., C=US'; $Script:SignatureStatus='Valid'
$failed=$false
try { Invoke-AutodeskComponentInstall Licensing } catch { $failed=$true }
if (-not $failed -or $Script:LaunchCount -ne 1) { throw 'Installer failure was ignored' }
$Script:InstallerExit=3010
Invoke-AutodeskComponentInstall Identity
$Script:SignatureStatus='NotSigned'
$failed=$false
try { Invoke-AutodeskComponentInstall Licensing } catch { $failed=$true }
if (-not $failed -or $Script:LaunchCount -ne 2) { throw 'Invalid signature reached execution' }
$Script:SignatureStatus='Valid'
function Get-AutodeskComponentInstaller { return 'C:\test folder\signed-installer.msi' }
function Start-Process {
    param($FilePath,$ArgumentList,[switch]$Wait,[switch]$PassThru,$ErrorAction)
    if ($FilePath -ne (Join-Path $env:WINDIR 'System32\msiexec.exe') -or $ArgumentList[0] -ne '/i' -or $ArgumentList[1] -ne '"C:\test folder\signed-installer.msi"' -or $ArgumentList[2] -ne '/norestart' -or -not $Wait) { throw 'Invalid MSI launch' }
    return [pscustomobject]@{ExitCode=0}
}
Invoke-AutodeskComponentInstall NLM
$failed=$false
try { Invoke-LicenseLocalCleanup } catch { $failed=$true }
if (-not $failed) { throw 'Backup failure did not stop cleanup' }
Write-Host 'PASS: localhost filtering, official links, signature, dry-run guards, exit codes, backup failure guard'
