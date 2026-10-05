# Offline checks. Defender and third-party products are never modified.
$ErrorActionPreference = 'Stop'
$errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot 'RevitToolkit.ps1'), [ref]$null, [ref]$errors)
if ($errors.Count) { throw ($errors | Out-String) }
foreach ($name in @('Set-ToolkitDefenderRealtime', 'Export-AntivirusExclusionList')) {
    $f = $ast.Find({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name}, $true)
    . ([scriptblock]::Create($f.Extent.Text))
}
function Get-UiText { param($ru,$en) return $en }
function Write-Info {}
function Write-Ok {}
function Write-Warn {}
function Test-DryRun { return $Script:DryRun }
function Assert-Admin { if ($Script:DryRun) { throw 'Admin check during dry run' }; return $true }
function Confirm-Action { param($Question,[switch]$Danger) return $Script:Confirm }
function Get-MpComputerStatus { return [pscustomobject]@{IsTamperProtected=$Script:Tamper;AntivirusEnabled=$true;RealTimeProtectionEnabled=$Script:Realtime} }
function Set-MpPreference {
    param([bool]$DisableRealtimeMonitoring,$ErrorAction)
    $Script:Writes++
    if (-not $Script:PolicyBlocks) { $Script:Realtime = -not $DisableRealtimeMonitoring }
}
function Get-ExclusionTargets { return @{'C:\Autodesk'='test'; 'C:\Program Files\Autodesk'='test'} }
$Script:DryRun=$true; $Script:Writes=0; $Script:Confirm=$true
Set-ToolkitDefenderRealtime $false
Export-AntivirusExclusionList
if ($Script:Writes) { throw 'Dry run changed protection' }
$Script:DryRun=$false; $Script:Tamper=$true; $Script:Realtime=$true
$blocked=$false
try { Set-ToolkitDefenderRealtime $false } catch { $blocked=$true }
if (-not $blocked -or $Script:Writes) { throw 'Tamper protection was bypassed' }
$Script:Tamper=$false; $Script:Confirm=$false
Set-ToolkitDefenderRealtime $false
if ($Script:Writes) { throw 'Cancelled action changed protection' }
$Script:Confirm=$true
Set-ToolkitDefenderRealtime $false
if ($Script:Realtime -or $Script:Writes -ne 1) { throw 'Disable failed' }
Set-ToolkitDefenderRealtime $true
if (-not $Script:Realtime -or $Script:Writes -ne 2) { throw 'Enable failed' }
$Script:PolicyBlocks=$true; $blocked=$false
try { Set-ToolkitDefenderRealtime $false } catch { $blocked=$true }
if (-not $blocked) { throw 'Policy rejection reported as success' }
$Script:Root=Join-Path $env:TEMP ('ToolkitAntivirusTest-' + [guid]::NewGuid().ToString('N'))
try {
    Export-AntivirusExclusionList
    $files=@(Get-ChildItem (Join-Path $Script:Root 'exports') -File)
    if ($files.Count -ne 1 -or @([IO.File]::ReadAllLines($files[0].FullName)).Count -ne 2) { throw 'Exclusion export failed' }
} finally {
    $resolved=[IO.Path]::GetFullPath($Script:Root)
    if (-not $resolved.StartsWith([IO.Path]::GetFullPath($env:TEMP).TrimEnd('\')+'\ToolkitAntivirusTest-', [StringComparison]::OrdinalIgnoreCase)) { throw 'Unsafe test cleanup' }
    if (Test-Path -LiteralPath $resolved) { Remove-Item -LiteralPath $resolved -Recurse -Force }
}
Write-Host 'PASS: dry run, tamper protection, cancellation, disable/enable, policy rejection, exclusion export'
