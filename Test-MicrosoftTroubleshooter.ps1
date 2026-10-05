# Offline checks: no real diagnostic package is downloaded or launched.
$ErrorActionPreference='Stop'
$errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot 'RevitToolkit.ps1'),[ref]$null,[ref]$errors)
if ($errors.Count) { throw ($errors | Out-String) }
$f=$ast.Find({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Start-PersonalAcceleratorTroubleshooter'},$true)
. ([scriptblock]::Create($f.Extent.Text))
function Get-UiText { param($ru,$en) return $en }
function Write-Info {}
function Write-Warn {}
function Get-PersonalAcceleratorEntry { return [pscustomobject]@{DisplayName='Personal Accelerator for Revit';ProductCode='{7E12D662-6D53-492A-8CCC-7FA7AA85A104}'} }
function Test-DryRun { return $Script:DryRun }
function Assert-Admin { if ($Script:DryRun) { throw 'Admin check during dry run' }; return $true }
function Get-Process { param($Name,$ErrorAction) }
function Confirm-Action { param($Question) return $Script:Confirm }
function Test-Path {
    param([Alias('Path')][string]$LiteralPath,[string]$PathType)
    if ($LiteralPath -eq (Join-Path $env:WINDIR 'System32\msdt.exe')) { return $true }
    if ($PathType) { return Microsoft.PowerShell.Management\Test-Path -LiteralPath $LiteralPath -PathType $PathType }
    return Microsoft.PowerShell.Management\Test-Path -LiteralPath $LiteralPath
}
function Get-FileHash { param($LiteralPath,$Algorithm) return [pscustomobject]@{Hash=$(if ($Script:BadHash) {'bad'} else {'8cad66adb36b1f4f64204a4328a063ae33695dbbd5386f761cfb56c2c0987471'})} }
function Get-AuthenticodeSignature { param($LiteralPath,$ErrorAction) return [pscustomobject]@{Status=$Script:SignatureStatus;SignerCertificate=[pscustomobject]@{Subject=$Script:Signer}} }
function Invoke-WebRequest { param($Uri,[switch]$UseBasicParsing,$OutFile,$TimeoutSec,$ErrorAction) $Script:Downloads++; if ($Uri -notlike 'https://download.microsoft.com/*') { throw 'Unofficial diagnostic source' }; [IO.File]::WriteAllText($OutFile,'mock cabinet') }
function Start-Process { param($FilePath,$ArgumentList,[switch]$Wait,[switch]$PassThru,$ErrorAction) $Script:Launches++; if ($FilePath -ne (Join-Path $env:WINDIR 'System32\msdt.exe') -or $ArgumentList[0] -ne '/cab' -or -not $Wait) { throw 'Wrong diagnostic launch' }; return [pscustomobject]@{ExitCode=0} }
$Script:Root=Join-Path $env:TEMP ('ToolkitMicrosoftTest-'+[guid]::NewGuid().ToString('N'))
$Script:DryRun=$true; $Script:Confirm=$true; $Script:Downloads=0; $Script:Launches=0
try {
    Start-PersonalAcceleratorTroubleshooter
    if ($Script:Downloads -or $Script:Launches -or (Test-Path $Script:Root)) { throw 'Dry run mutated system' }
    $Script:DryRun=$false; $Script:Confirm=$false
    Start-PersonalAcceleratorTroubleshooter
    if ($Script:Downloads -or $Script:Launches) { throw 'Cancelled action mutated system' }
    $Script:Confirm=$true; $Script:BadHash=$true; $rejected=$false
    try { Start-PersonalAcceleratorTroubleshooter } catch { $rejected=$true }
    if (-not $rejected -or $Script:Launches) { throw 'Bad diagnostic hash accepted' }
    $Script:BadHash=$false; $Script:SignatureStatus='NotSigned'; $Script:Signer='O=Microsoft Corporation, C=US'; $rejected=$false
    try { Start-PersonalAcceleratorTroubleshooter } catch { $rejected=$true }
    if (-not $rejected -or $Script:Launches) { throw 'Unsigned diagnostic accepted' }
    $Script:SignatureStatus='Valid'; $Script:Signer='O=Other, C=US'; $rejected=$false
    try { Start-PersonalAcceleratorTroubleshooter } catch { $rejected=$true }
    if (-not $rejected -or $Script:Launches) { throw 'Wrong publisher accepted' }
    $Script:Signer='CN=Microsoft Corporation, O=Microsoft Corporation, C=US'; $before=$Script:Downloads
    Start-PersonalAcceleratorTroubleshooter
    if ($Script:Launches -ne 1 -or $Script:Downloads -ne $before) { throw 'Verified cache/launch failed' }
} finally {
    $resolved=[IO.Path]::GetFullPath($Script:Root)
    if (-not $resolved.StartsWith([IO.Path]::GetFullPath($env:TEMP).TrimEnd('\')+'\ToolkitMicrosoftTest-', [StringComparison]::OrdinalIgnoreCase)) { throw 'Unsafe test cleanup' }
    if (Test-Path -LiteralPath $resolved) { Remove-Item -LiteralPath $resolved -Recurse -Force }
}
Write-Host 'PASS: dry run, cancellation, official download, hash/signature/publisher rejection, verified cache and diagnostic launch'
