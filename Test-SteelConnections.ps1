# Offline checks: temporary manifests and mocked registry/sector information only.
$ErrorActionPreference='Stop'
$errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot 'RevitToolkit.ps1'),[ref]$null,[ref]$errors)
if ($errors.Count) { throw ($errors | Out-String) }
foreach ($name in @('ConvertFrom-SectorInfo','Set-SteelConnectionsEnabled','Set-SteelNvmeWorkaround')) {
    $f=$ast.Find({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name},$true)
    . ([scriptblock]::Create($f.Extent.Text))
}
if ((ConvertFrom-SectorInfo "PhysicalBytesPerSectorForAtomicity : 4096`nPhysicalBytesPerSectorForPerformance : 65536") -ne 65536) { throw 'Largest sector not selected' }
$blocked=$false
try { ConvertFrom-SectorInfo 'Unknown localized output: 65536' } catch { $blocked=$true }
if (-not $blocked) { throw 'Unknown sector output accepted' }
function Get-UiText { param($ru,$en) return $en }
function Write-Info {}
function Write-Warn {}
function Write-Ok {}
function Test-DryRun { return $Script:DryRun }
function Assert-Admin { if ($Script:DryRun) { throw 'Admin check during dry run' }; return $true }
function Get-Process { param($Name,$ErrorAction) if ($Script:Running) { return [pscustomobject]@{Name='Revit'} } }
function Confirm-Action { param($Question,[switch]$Danger) return $Script:Confirm }
function Get-SteelManifestPaths { param($Version) return $Script:Manifests }
function Get-SteelSectorInfo { return [pscustomobject]@{Bytes=$Script:SectorBytes;Text='mock sector info'} }
function Get-NvmeSectorSetting { return $Script:Setting }
function Move-Item {
    param($LiteralPath,$Destination,$ErrorAction)
    if ($Script:FailSecondRename -and $LiteralPath -eq $Script:Manifests[1]) { throw 'Mock second manifest rename failed' }
    Microsoft.PowerShell.Management\Move-Item -LiteralPath $LiteralPath -Destination $Destination -ErrorAction Stop
}
function Set-Content {
    param($LiteralPath,$Encoding,[Parameter(ValueFromPipeline=$true)]$Value)
    process { if ($Script:FailBackup) { throw 'Mock backup failure' }; Microsoft.PowerShell.Management\Set-Content -LiteralPath $LiteralPath -Value $Value -Encoding $Encoding -ErrorAction Stop }
}
function New-Item {
    param($Path,$ItemType,[switch]$Force,$ErrorAction)
    if ($Path -like 'HKLM:*') { if ($Path -ne 'HKLM:\SYSTEM\CurrentControlSet\Services\stornvme\Parameters\Device') { throw 'Unexpected registry path' }; return }
    Microsoft.PowerShell.Management\New-Item -Path $Path -ItemType $ItemType -Force -ErrorAction Stop
}
function New-ItemProperty {
    param($Path,$Name,$PropertyType,$Value,[switch]$Force,$ErrorAction)
    if ($Path -ne 'HKLM:\SYSTEM\CurrentControlSet\Services\stornvme\Parameters\Device' -or $Name -ne 'ForcedPhysicalSectorSizeInBytes' -or $PropertyType -ne 'MultiString') { throw 'Unexpected registry mutation' }
    $Script:Writes++; $Script:Setting=[pscustomobject]@{Version=1;PropertyExists=$true;Kind='MultiString';Value=@($Value)}
}
function Remove-ItemProperty {
    param($LiteralPath,$Name,$ErrorAction)
    if ($LiteralPath -ne 'HKLM:\SYSTEM\CurrentControlSet\Services\stornvme\Parameters\Device' -or $Name -ne 'ForcedPhysicalSectorSizeInBytes') { throw 'Unexpected registry removal' }
    $Script:Writes++; $Script:Setting=[pscustomobject]@{Version=1;PropertyExists=$false;Kind='';Value=@()}
}
function Test-Path {
    param([Alias('Path')][string]$LiteralPath,[string]$PathType)
    if ($LiteralPath -eq 'HKLM:\SYSTEM\CurrentControlSet\Services\stornvme') { return $true }
    if ($PathType) { return Microsoft.PowerShell.Management\Test-Path -LiteralPath $LiteralPath -PathType $PathType }
    return Microsoft.PowerShell.Management\Test-Path -LiteralPath $LiteralPath
}
$root=Join-Path $env:TEMP ('ToolkitSteelTest-'+[guid]::NewGuid().ToString('N'))
$oldProgramData=$env:ProgramData
$Script:Writes=0; $Script:DryRun=$true; $Script:Confirm=$true; $Script:SectorBytes=65536
try {
    New-Item -Path $root -ItemType Directory -Force | Out-Null
    $env:ProgramData=$root
    $Script:Manifests=@((Join-Path $root 'Autodesk.SteelConnectionsDB.addin'),(Join-Path $root 'Autodesk.SteelConnectionsUI.addin'))
    foreach ($path in $Script:Manifests) { [IO.File]::WriteAllText($path,'original manifest') }
    Set-SteelConnectionsEnabled 2022 $false
    Set-SteelNvmeWorkaround
    if ($Script:Writes -or -not (Test-Path $Script:Manifests[0])) { throw 'Dry run modified state' }
    $Script:DryRun=$false; $Script:Running=$true; $blocked=$false
    try { Set-SteelConnectionsEnabled 2022 $false } catch { $blocked=$true }
    if (-not $blocked) { throw 'Running Revit was ignored' }
    $Script:Running=$false
    Set-SteelConnectionsEnabled 2022 $false
    foreach ($path in $Script:Manifests) { if ((Test-Path $path) -or -not (Test-Path ($path+'.revittoolkit-disabled'))) { throw 'Manifest not disabled' } }
    Set-SteelConnectionsEnabled 2022 $true
    foreach ($path in $Script:Manifests) { if ([IO.File]::ReadAllText($path) -ne 'original manifest') { throw 'Manifest bytes changed during restore' } }
    [IO.File]::WriteAllText(($Script:Manifests[0]+'.revittoolkit-disabled'),'conflict')
    $blocked=$false
    try { Set-SteelConnectionsEnabled 2022 $false } catch { $blocked=$true }
    if (-not $blocked -or -not (Test-Path $Script:Manifests[1])) { throw 'Conflicting manifests overwritten' }
    Remove-Item -LiteralPath ($Script:Manifests[0]+'.revittoolkit-disabled')
    $Script:FailSecondRename=$true; $blocked=$false
    try { Set-SteelConnectionsEnabled 2022 $false } catch { $blocked=$true }
    if (-not $blocked -or -not (Test-Path $Script:Manifests[0]) -or -not (Test-Path $Script:Manifests[1])) { throw 'Partial manifest rename was not rolled back' }
    $Script:FailSecondRename=$false
    $Script:Setting=[pscustomobject]@{Version=1;PropertyExists=$true;Kind='MultiString';Value=@('device 4095','other 4095')}
    $Script:SectorBytes=4096; $blocked=$false
    try { Set-SteelNvmeWorkaround } catch { $blocked=$true }
    if (-not $blocked -or $Script:Writes) { throw 'Workaround applied to a supported sector' }
    $Script:SectorBytes=65536; $Script:Confirm=$false
    Set-SteelNvmeWorkaround
    if ($Script:Writes) { throw 'Cancelled workaround wrote registry' }
    $Script:Confirm=$true
    $Script:FailBackup=$true; $blocked=$false
    try { Set-SteelNvmeWorkaround } catch { $blocked=$true }
    if (-not $blocked -or $Script:Writes) { throw 'Registry changed after backup failure' }
    $Script:FailBackup=$false
    Set-SteelNvmeWorkaround
    if ($Script:Setting.Value[0] -ne '* 4095') { throw 'Workaround was not applied' }
    Set-SteelNvmeWorkaround -Restore
    if (($Script:Setting.Value -join ',') -ne 'device 4095,other 4095') { throw 'Original multi-string was not restored' }
    $Script:Setting=[pscustomobject]@{Version=1;PropertyExists=$false;Kind='';Value=@()}
    Set-SteelNvmeWorkaround
    $Script:Setting.Value=@('externally changed'); $blocked=$false
    try { Set-SteelNvmeWorkaround -Restore } catch { $blocked=$true }
    if (-not $blocked) { throw 'External registry change overwritten on rollback' }
    $Script:Setting.Value=@('* 4095')
    Set-SteelNvmeWorkaround -Restore
    if ($Script:Setting.PropertyExists) { throw 'Originally absent value was not removed' }
} finally {
    $env:ProgramData=$oldProgramData
    $resolved=[IO.Path]::GetFullPath($root)
    if (-not $resolved.StartsWith([IO.Path]::GetFullPath($env:TEMP).TrimEnd('\')+'\ToolkitSteelTest-', [StringComparison]::OrdinalIgnoreCase)) { throw 'Unsafe test cleanup' }
    if (Test-Path -LiteralPath $resolved) { Remove-Item -LiteralPath $resolved -Recurse -Force }
}
Write-Host 'PASS: sector parsing/guard, dry run, Revit guard, manifest disable/restore/conflict, backup, exact registry restore and external-change protection'
