# Real file round-trips in a temporary folder; no Autodesk files are modified.
param([ValidateSet('ru', 'en')][string]$Language = 'ru')
$ErrorActionPreference = 'Stop'
$Script:UiLanguage = $Language
$ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot 'RevitToolkit.ps1'), [ref]$null, [ref]$null)
foreach ($name in @('Get-UiText', 'Get-RsnPath', 'Test-RsnAddress', 'Get-RsnLines', 'Get-RsnEntries', 'Update-RsnLines', 'Save-RsnLines')) {
    $f = $ast.Find({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name }, $true)
    . ([scriptblock]::Create($f.Extent.Text))
}
foreach ($address in @('SRV-BIM01', 'revit.company.local', '192.168.1.10')) {
    if (-not (Test-RsnAddress $address)) { throw "Rejected valid address: $address" }
}
foreach ($address in @('', '_server', 'https://server', 'server:80', 'server name', "server`nother", ('a' * 64), '999.1.1.1', '127.1', '.server')) {
    if (Test-RsnAddress $address) { throw "Accepted invalid address: $address" }
}
$lines = @('; keep this comment', 'old-server', '', 'other-server')
$edited = @(Update-RsnLines $lines -Action Edit -Index 1 -Address 'new-server')
if (($edited -join '|') -ne '; keep this comment|new-server||other-server') { throw 'Edit changed unrelated lines' }
$removed = @(Update-RsnLines $edited -Action Remove -Index 3)
if (($removed -join '|') -ne '; keep this comment|new-server|') { throw 'Removal changed unrelated lines' }
$duplicateRejected = $false
try { Update-RsnLines $edited -Action Add -Address 'NEW-SERVER' | Out-Null } catch { $duplicateRejected = $true }
if (-not $duplicateRejected) { throw 'Case-insensitive duplicate accepted' }
$folder = Join-Path ([IO.Path]::GetTempPath()) ('RevitToolkit-RSN-test-' + [guid]::NewGuid())
$path = Join-Path $folder 'Config\RSN.ini'
$Script:DryTest = $true
function Write-Info {}
function Write-Ok {}
function Test-DryRun { return $Script:DryTest }
function Assert-Admin { return $true }
function Confirm-Action { return $true }
try {
    Save-RsnLines $path @('first-server')
    if (Test-Path -LiteralPath $folder) { throw 'Dry run created a directory' }
    $Script:DryTest = $false
    Save-RsnLines $path @('first-server')
    if ((Get-RsnLines $path) -ne 'first-server') { throw 'Create/read failed' }
    $originalBytes = [Convert]::ToBase64String([IO.File]::ReadAllBytes($path))
    $added = @(Update-RsnLines @(Get-RsnLines $path) -Action Add -Address 'second-server')
    Save-RsnLines $path $added
    $backups = @(Get-ChildItem -LiteralPath (Split-Path $path) -Filter '*.bak')
    if ($backups.Count -ne 1 -or [Convert]::ToBase64String([IO.File]::ReadAllBytes($backups[0].FullName)) -ne $originalBytes) { throw 'Exact backup missing' }
    if ((@(Get-RsnLines $path) -join '|') -ne 'first-server|second-server') { throw 'Add/save failed' }
    $Script:DryTest = $true
    Save-RsnLines $path @('dry-change')
    if ((@(Get-RsnLines $path) -join '|') -ne 'first-server|second-server') { throw 'Dry run changed a file' }
    $Script:DryTest = $false
    Save-RsnLines $path @()
    if ([IO.File]::ReadAllBytes($path).Length -ne 0) { throw 'Empty list failed' }
    if (@(Get-ChildItem -LiteralPath (Split-Path $path) -Filter '*.tmp').Count) { throw 'Temporary file left behind' }
} finally {
    # Explicit, checked temporary test directory only.
    $resolved = [IO.Path]::GetFullPath($folder)
    $tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
    if (-not $resolved.StartsWith($tempRoot, [StringComparison]::OrdinalIgnoreCase) -or (Split-Path $resolved -Leaf) -notlike 'RevitToolkit-RSN-test-*') { throw 'Unsafe test cleanup path' }
    if (Test-Path -LiteralPath $resolved) { Remove-Item -LiteralPath $resolved -Recurse -Force }
}
Write-Host 'PASS: RSN addresses, add/edit/remove, duplicate rejection, creation, exact backup, dry run, empty list'
