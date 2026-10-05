# Offline checks: Windows Installer, registry and Autodesk applications are mocked.
$ErrorActionPreference='Stop'
$errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot 'RevitToolkit.ps1'),[ref]$null,[ref]$errors)
if ($errors.Count) { throw ($errors | Out-String) }
foreach ($name in @('Get-PersonalAcceleratorProductCode','Get-PersonalAcceleratorEntry','Invoke-PersonalAcceleratorRemoval')) {
    $f=$ast.Find({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name},$true)
    . ([scriptblock]::Create($f.Extent.Text))
}
function Get-UiText { param($ru,$en) return $en }
function Write-Info {}
function Write-Warn {}
function Write-Ok { $Script:Success++ }
$code='{7E12D662-6D53-492A-8CCC-7FA7AA85A104}'
$entry=[pscustomobject]@{DisplayName='Personal Accelerator for Revit';DisplayVersion='24.4.21.0';Publisher='Autodesk';ProductKey=$code;UninstallString=('MsiExec.exe /X'+$code);RegistryPath='test-registry'}
if ((Get-PersonalAcceleratorProductCode $entry) -ne $code) { throw 'Official MSI not recognized' }
foreach ($command in @('cmd.exe /c msiexec /x'+$code, 'msiexec /x'+$code+' & echo bad', 'msiexec /x'+$code+' /x{00000000-0000-0000-0000-000000000000}')) {
    $bad=$entry.PSObject.Copy(); $bad.UninstallString=$command
    if (Get-PersonalAcceleratorProductCode $bad) { throw 'Unsafe uninstall command accepted' }
}
$bad=$entry.PSObject.Copy(); $bad.DisplayName='Autodesk Revit 2024'
if (Get-PersonalAcceleratorProductCode $bad) { throw 'Revit accepted as Personal Accelerator' }
$bad=$entry.PSObject.Copy(); $bad.Publisher='Other'
if (Get-PersonalAcceleratorProductCode $bad) { throw 'Other publisher accepted' }
$bad=$entry.PSObject.Copy(); $bad.ProductKey='{00000000-0000-0000-0000-000000000000}'
if (Get-PersonalAcceleratorProductCode $bad) { throw 'Conflicting product code accepted' }
$Script:Entries=@($entry,$entry.PSObject.Copy())
function Get-UninstallEntry { return $Script:Entries }
if (@(Get-PersonalAcceleratorEntry).Count -ne 1) { throw 'Duplicate MSI registration was not collapsed' }
function Test-DryRun { return $Script:DryRun }
function Assert-Admin { if ($Script:DryRun) { throw 'Admin check in dry run' }; return $true }
function Confirm-Action { param($Question,[switch]$Danger) return $Script:Confirm }
function Get-Process { param($Name,$ErrorAction) if ($Script:RevitRunning) { return [pscustomobject]@{Name='Revit'} } }
function Start-Process {
    param($FilePath,$ArgumentList,[switch]$Wait,[switch]$PassThru,$ErrorAction)
    $Script:Launches++
    if ($FilePath -ne (Join-Path $env:WINDIR 'System32\msiexec.exe') -or $ArgumentList[0] -ne '/x' -or $ArgumentList[1] -ne $code -or $ArgumentList[2] -ne '/norestart' -or $ArgumentList[3] -ne '/L*v' -or -not $Wait) { throw 'Unsafe MSI launch' }
    if ($Script:ExitCode -eq 0 -and -not $Script:KeepRegistration) { $Script:Entries=@() }
    return [pscustomobject]@{ExitCode=$Script:ExitCode}
}
$Script:Root=Join-Path $env:TEMP ('ToolkitPacrTest-'+[guid]::NewGuid().ToString('N'))
$Script:Launches=0; $Script:Success=0; $Script:DryRun=$true; $Script:Confirm=$true
try {
    Invoke-PersonalAcceleratorRemoval
    if ($Script:Launches -or (Test-Path $Script:Root)) { throw 'Dry run performed mutations' }
    $Script:DryRun=$false; $Script:RevitRunning=$true; $blocked=$false
    try { Invoke-PersonalAcceleratorRemoval } catch { $blocked=$true }
    if (-not $blocked -or $Script:Launches) { throw 'Running Revit was ignored' }
    $Script:RevitRunning=$false; $Script:Confirm=$false
    Invoke-PersonalAcceleratorRemoval
    if ($Script:Launches -or (Test-Path $Script:Root)) { throw 'Cancelled action performed mutations' }
    $Script:Confirm=$true; $Script:ExitCode=1603; $blocked=$false
    try { Invoke-PersonalAcceleratorRemoval } catch { $blocked=$true }
    if (-not $blocked -or $Script:Success) { throw 'MSI failure reported as success' }
    $Script:ExitCode=1602
    Invoke-PersonalAcceleratorRemoval
    if ($Script:Success) { throw 'Installer cancellation reported as success' }
    $Script:ExitCode=3010
    Invoke-PersonalAcceleratorRemoval
    if ($Script:Success) { throw 'Pending reboot reported as completed uninstall' }
    $Script:ExitCode=0; $Script:KeepRegistration=$true; $blocked=$false
    try { Invoke-PersonalAcceleratorRemoval } catch { $blocked=$true }
    if (-not $blocked) { throw 'Remaining registration ignored' }
    $Script:KeepRegistration=$false
    Invoke-PersonalAcceleratorRemoval
    if ($Script:Success -ne 1 -or $Script:Entries.Count) { throw 'Successful uninstall verification failed' }
} finally {
    $resolved=[IO.Path]::GetFullPath($Script:Root)
    if (-not $resolved.StartsWith([IO.Path]::GetFullPath($env:TEMP).TrimEnd('\')+'\ToolkitPacrTest-', [StringComparison]::OrdinalIgnoreCase)) { throw 'Unsafe test cleanup' }
    if (Test-Path -LiteralPath $resolved) { Remove-Item -LiteralPath $resolved -Recurse -Force }
}
Write-Host 'PASS: product identity, MSI validation, deduplication, dry run, Revit guard, cancellation, failure/reboot, result verification'
