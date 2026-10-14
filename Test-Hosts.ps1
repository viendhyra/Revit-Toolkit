# Offline checks: use a temporary Windows tree, never the system hosts file.
$ErrorActionPreference = 'Stop'
$errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot 'RevitToolkit.ps1'), [ref]$null, [ref]$errors)
if ($errors.Count) { throw ($errors | Out-String) }
$f = $ast.Find({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Invoke-ToolkitHostsUpdate'}, $true)
. ([scriptblock]::Create($f.Extent.Text))
function Get-UiText { param($ru,$en) $en }
function Write-Info {}
function Write-Ok {}
function Test-DryRun { $Script:DryRun }
function Assert-Admin { $true }
function Confirm-Action { $Script:Confirmed }
function Clear-DnsClientCache { $Script:FlushCount++ }
function Invoke-WebRequest {
    param($Uri,[switch]$UseBasicParsing,$OutFile,$TimeoutSec,$ErrorAction)
    if ($Uri -ne 'https://raw.githubusercontent.com/viendhyra/Revit-Toolkit/main/hosts') { throw 'Wrong hosts source' }
    $Script:Downloads++
    if ($Script:Corrupt) { [IO.File]::WriteAllText($OutFile, '<html>error</html>') }
    else { Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'hosts') -Destination $OutFile }
}
$savedWindir = $env:WINDIR; $savedProgramData = $env:ProgramData
$Script:Root = Join-Path $env:TEMP ('ToolkitHostsTest-' + [guid]::NewGuid().ToString('N'))
$Script:DryRun = $true; $Script:Confirmed = $true; $Script:Downloads = 0; $Script:FlushCount = 0
try {
    $env:WINDIR = Join-Path $Script:Root 'Windows'
    $env:ProgramData = Join-Path $Script:Root 'ProgramData'
    $target = Join-Path $env:WINDIR 'System32\drivers\etc\hosts'
    New-Item -ItemType Directory -Path (Split-Path $target) -Force | Out-Null
    [IO.File]::WriteAllText($target, 'original hosts')
    Invoke-ToolkitHostsUpdate
    if ($Script:Downloads -or $Script:FlushCount) { throw 'Dry run changed the PC' }
    $Script:DryRun = $false; $Script:Confirmed = $false
    Invoke-ToolkitHostsUpdate
    if ($Script:Downloads) { throw 'Cancelled operation downloaded hosts' }
    $Script:Confirmed = $true; $Script:Corrupt = $true
    $failed = $false
    try { Invoke-ToolkitHostsUpdate } catch { $failed = $_.Exception.Message -eq 'Hosts SHA256 mismatch' }
    if (-not $failed -or [IO.File]::ReadAllText($target) -ne 'original hosts') { throw 'Invalid download changed hosts' }
    $Script:Corrupt = $false
    function Copy-Item { param($LiteralPath,$Destination,$ErrorAction,[switch]$Force) if ($Destination -like '*.bak') { throw 'Backup failed' }; Microsoft.PowerShell.Management\Copy-Item -LiteralPath $LiteralPath -Destination $Destination -Force:$Force -ErrorAction Stop }
    $failed = $false
    try { Invoke-ToolkitHostsUpdate } catch { $failed = $_.Exception.Message -eq 'Backup failed' }
    if (-not $failed -or [IO.File]::ReadAllText($target) -ne 'original hosts') { throw 'Backup failure changed hosts' }
    Remove-Item Function:\Copy-Item
    Invoke-ToolkitHostsUpdate
    if ((Get-FileHash $target).Hash -ne (Get-FileHash (Join-Path $PSScriptRoot 'hosts')).Hash -or $Script:FlushCount -ne 1) { throw 'Replacement or DNS flush failed' }
    $backups = @(Get-ChildItem (Join-Path $env:ProgramData 'RevitToolkit\HostsBackups') -File)
    if ($backups.Count -ne 1 -or [IO.File]::ReadAllText($backups[0].FullName) -ne 'original hosts') { throw 'Original hosts not backed up' }
    if (@(Get-ChildItem (Join-Path $Script:Root 'components') -Recurse -File).Count) { throw 'Temporary download remains' }
} finally {
    $env:WINDIR = $savedWindir; $env:ProgramData = $savedProgramData
    $resolved = [IO.Path]::GetFullPath($Script:Root)
    if (-not $resolved.StartsWith([IO.Path]::GetFullPath($env:TEMP).TrimEnd('\') + '\ToolkitHostsTest-', [StringComparison]::OrdinalIgnoreCase)) { throw 'Unsafe cleanup' }
    if (Test-Path $resolved) { Remove-Item -LiteralPath $resolved -Recurse -Force }
}
Write-Host 'PASS: hosts source, dry run, cancellation, hash, backup failure, replacement and backup'
