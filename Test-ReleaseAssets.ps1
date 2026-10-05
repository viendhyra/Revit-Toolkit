# Validate every package before uploading release components-2026-10-05.
$ErrorActionPreference = 'Stop'
$ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot 'RevitToolkit.ps1'), [ref]$null, [ref]$null)
foreach ($name in @('Get-UiText','Get-ToolkitComponentAsset','Assert-AutodeskInstaller')) {
    $f = $ast.Find({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name}, $true)
    . ([scriptblock]::Create($f.Extent.Text))
}
$missing = @()
foreach ($component in @('Identity','NLM','FAB')) {
    $asset = Get-ToolkitComponentAsset $component
    $path = Join-Path $PSScriptRoot ('release-assets\' + $asset.Name)
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { $missing += $asset.Name; continue }
    if ((Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -ine $asset.Sha256) { throw "SHA256 mismatch: $path" }
    if ($component -ne 'FAB') { Assert-AutodeskInstaller $path }
    Write-Host "PASS: $component $($asset.Version)"
}
if ($missing.Count) { throw ('Release incomplete: ' + ($missing -join ', ')) }
Write-Host 'PASS: all release assets ready for upload'
