# Offline checks: no downloads or installation.
$ErrorActionPreference = 'Stop'
$errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot 'RevitToolkit.ps1'), [ref]$null, [ref]$errors)
if ($errors.Count) { throw ($errors | Out-String) }
foreach ($name in @('Get-ToolkitComponentAsset','Get-ToolkitComponentPackage')) {
    $f = $ast.Find({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name}, $true)
    . ([scriptblock]::Create($f.Extent.Text))
}
foreach ($component in @('Identity','NLM','FAB')) {
    $asset = Get-ToolkitComponentAsset $component
    if ($asset.Sha256 -notmatch '^[a-f0-9]{64}$' -or $asset.Url -ne ('https://github.com/viendhyra/Revit-Toolkit/releases/download/components-2026-10-05/' + $asset.Name)) { throw 'Invalid pinned asset' }
}
function Get-UiText { param($ru,$en) return $en }
function Write-Info {}
function Assert-AutodeskInstaller { param($Path) $Script:SignatureChecks++ }
function Test-DryRun { return $Script:DryRun }
function Invoke-WebRequest { param($Uri,[switch]$UseBasicParsing,$OutFile,$ErrorAction) $Script:Downloads++; [IO.File]::WriteAllText($OutFile,'test package') }
$Script:DryRun = $true
$Script:Downloads = 0
if (Get-ToolkitComponentPackage FAB) { throw 'Dry run returned a package' }
if ($Script:Downloads) { throw 'Dry run downloaded a package' }
$Script:Root = Join-Path $env:TEMP ('ToolkitComponentsTest-' + [guid]::NewGuid().ToString('N'))
$Script:DryRun = $false
$Script:SignatureChecks = 0
try {
    $asset = Get-ToolkitComponentAsset FAB
    $rejected = $false
    try { Get-ToolkitComponentPackage FAB } catch { $rejected = $_.Exception.Message -eq 'Component SHA256 mismatch' }
    if (-not $rejected) { throw 'Corrupt download accepted' }
    $folder = Join-Path $Script:Root ('components\FAB\' + $asset.Version)
    if (@(Get-ChildItem -LiteralPath $folder -File).Count) { throw 'Failed download remains in cache' }
    $realPackage = Join-Path $PSScriptRoot 'release-assets\fab.zip'
    if (Test-Path -LiteralPath $realPackage) {
        Copy-Item -LiteralPath $realPackage -Destination (Join-Path $folder $asset.Name)
        $before = $Script:Downloads
        $path = Get-ToolkitComponentPackage FAB
        if (-not $path -or $Script:Downloads -ne $before) { throw 'Verified cache was downloaded again' }
    }
} finally {
    $resolved = [IO.Path]::GetFullPath($Script:Root)
    if (-not $resolved.StartsWith([IO.Path]::GetFullPath($env:TEMP).TrimEnd('\') + '\ToolkitComponentsTest-', [StringComparison]::OrdinalIgnoreCase)) { throw 'Unsafe test cleanup' }
    if (Test-Path -LiteralPath $resolved) { Remove-Item -LiteralPath $resolved -Recurse -Force }
}
Write-Host 'PASS: pinned assets, dry run, corrupt download rejection, cleanup and verified cache'
