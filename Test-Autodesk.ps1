# Offline checks: no Defender or Firewall settings are changed.
param([ValidateSet('ru', 'en')][string]$Language = 'ru')
$Script:UiLanguage = $Language
$ErrorActionPreference = 'Stop'
$tokens = $null; $errors = $null
$path = Join-Path $PSScriptRoot 'RevitToolkit.ps1'
$ast = [Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw ($errors.Message -join "`n") }
$bytes = [IO.File]::ReadAllBytes($path)
if ($bytes[0] -ne 239 -or $bytes[1] -ne 187 -or $bytes[2] -ne 191) { throw 'UTF-8 BOM missing' }
$languageFunction = $ast.Find({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Get-UiText' }, $true)
. ([scriptblock]::Create($languageFunction.Extent.Text))
$module = $ast.Find({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Invoke-ModuleAutodesk' }, $true)
foreach ($f in $module.Body.FindAll({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] }, $true)) {
    . ([scriptblock]::Create($f.Extent.Text))
}
$Script:Ctx = [pscustomobject]@{ DryRun=$true; IsAdmin=$false }
function Write-Log {}
function Write-Info {}
function Write-Ok {}
function Write-Warn {}
function Write-Fail {}
function Assert-Admin { throw 'Unexpected admin check in dry run' }
function Confirm-Action { throw 'Unexpected confirmation in dry run' }
function Test-DryRun { return $Script:Ctx.DryRun }
function Test-DefenderReady { return $true }
function Get-ExclusionTargets { return @{ 'C:\Autodesk'='test' } }
function Get-ProductExecutables { return @('C:\Autodesk\Revit.exe') }
function Get-AllAutodeskExecutables { return @('C:\Autodesk\Revit.exe') }
function Read-State { return [pscustomobject]@{ Paths=@('C:\Autodesk'); Processes=@('Revit.exe') } }
function Get-CurrentExclusions { throw 'Unexpected Defender read after dry-run guard' }
function Add-MpPreference { throw 'Unexpected Defender mutation' }
function Remove-MpPreference { throw 'Unexpected Defender mutation' }
function New-NetFirewallRule { throw 'Unexpected firewall mutation' }
function Get-NetFirewallRule { throw 'Unexpected firewall read after dry-run guard' }
function Save-State { throw 'Unexpected state write' }
$ProcessList = @('Revit.exe')
Invoke-Install
Invoke-Remove
Set-ProductInternet Revit $true
Set-ProductInternet Revit $false
Set-AllAutodeskInternet $true
Set-AllAutodeskInternet $false
$FirewallPrefix = 'ADE-NET'
$first = Get-NetRuleName Revit 'C:\Autodesk\Revit 2026\Revit.exe'
$second = Get-NetRuleName Revit 'D:\Autodesk\Revit 2026\Revit.exe'
if ($first -eq $second) { throw 'Firewall rule names collide' }
if ($first -ne (Get-NetRuleName Revit 'c:\autodesk\revit 2026\revit.exe')) { throw 'Rule hash must ignore case' }
$nlmBase = ${env:ProgramFiles(x86)}
if (-not $nlmBase) { $nlmBase = $env:ProgramFiles }
$nlmFolder = Join-Path $nlmBase 'Common Files\Autodesk Shared\Network License Manager'
function Test-Path { return $true }
function Get-ChildItem {
    param($LiteralPath)
    if ($LiteralPath -ne $nlmFolder) { throw 'Unexpected NLM search root' }
    return @(
        [pscustomobject]@{ Name='lmgrd.exe'; FullName=(Join-Path $nlmFolder 'lmgrd.exe') },
        [pscustomobject]@{ Name='adskflex.exe'; FullName=(Join-Path $nlmFolder 'adskflex.exe') },
        [pscustomobject]@{ Name='Revit.exe'; FullName=(Join-Path $nlmFolder 'Revit.exe') }
    )
}
if (@(Get-NlmExecutables).Count -ne 2) { throw 'NLM discovery must exclude Revit.exe' }
Set-NlmInternet $true
Set-NlmInternet $false
$Script:Ctx.DryRun = $false
function Assert-Admin { return $true }
function Confirm-Action { return $true }
$Script:NlmRules = @()
function Get-NetFirewallRule { return $null }
function New-NetFirewallRule {
    param($Name, $DisplayName, $Group, $Direction, $Action, $Program, $Profile, $Enabled, $ErrorAction)
    if ($Group -ne 'Revit Toolkit - Network License Manager' -or $Direction -ne 'Outbound' -or $Action -ne 'Block' -or $Profile -ne 'Any') { throw 'Wrong NLM firewall scope' }
    if ($Program -notlike "$nlmFolder\*" -or [IO.Path]::GetFileName($Program) -ieq 'Revit.exe') { throw 'Unexpected program blocked' }
    $Script:NlmRules += $Program
}
Set-NlmInternet $true
if ($Script:NlmRules.Count -ne 2) { throw 'NLM rules not created' }
# Exercise real exclusion discovery with a simulated installation layout.
$discovery = $module.Body.Find({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Get-ExclusionTargets' }, $true)
. ([scriptblock]::Create($discovery.Extent.Text))
$PF = 'C:\Program Files'; $PF86 = 'C:\Program Files (x86)'; $PD = 'C:\ProgramData'
$UsersRoot = 'C:\Users'
$NamePattern = 'Autodesk|Revit|pyRevit|^AutoCAD|^Civil 3D|^3ds Max|^Inventor|^Maya|^Navisworks|^Adsk|^RVT\s*20\d{2}'
$ExtraFile = 'C:\missing-extra-test.txt'
$Forbidden = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
foreach ($root in @($PF, $PF86, $PD, $UsersRoot, 'C:', "$PF\Common Files", "$PF86\Common Files")) { [void]$Forbidden.Add($root) }
$existing = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
$fixtureFolders = @(
    $PF, $PF86, $PD,
    "$PF\Autodesk", "$PF86\Common Files\Autodesk Shared", "$PF\Common Files\Autodesk",
    "$env:SystemDrive\Autodesk", "$PD\RVT 2026", "$PF\3ds Max 2026",
    'D:\BIM\Maya', 'C:\Users\Artist\AppData\LocalLow',
    'C:\Users\Artist\AppData\LocalLow\AutoCAD',
    'C:\Users\Artist\AppData\Local\Autodesk', 'C:\Users\Artist\AppData\Local'
)
foreach ($folder in $fixtureFolders) { [void]$existing.Add($folder) }
function Test-Path { param($LiteralPath, $PathType) return $existing.Contains($LiteralPath) }
function Get-UserProfilePaths { return @('C:\Users\Artist') }
function Get-ChildItem {
    param($LiteralPath)
    foreach ($folder in $fixtureFolders) {
        if ((Split-Path $folder -Parent) -ieq $LiteralPath) { [pscustomobject]@{ Name=(Split-Path $folder -Leaf); FullName=$folder } }
    }
}
function Get-ItemProperty {
    return @(
        [pscustomobject]@{ Publisher='Autodesk'; InstallLocation='D:\BIM\Maya' },
        [pscustomobject]@{ Publisher='Autodesk'; InstallLocation='C:\' }
    )
}
$targets = Get-ExclusionTargets
foreach ($expected in @(
    "$PF86\Common Files\Autodesk Shared\Network License Manager\lmgrd.exe",
    "$PF\Common Files\Autodesk\component.exe", "$env:SystemDrive\Autodesk\installer.exe",
    "$PD\RVT 2026\cache.dat", "$PF\3ds Max 2026\3dsmax.exe", 'D:\BIM\Maya\maya.exe',
    'C:\Users\Artist\AppData\LocalLow\AutoCAD\cache.dat'
)) {
    $covered = @($targets.Keys | Where-Object { $expected.StartsWith($_ + '\', [StringComparison]::OrdinalIgnoreCase) })
    if (-not $covered.Count) { throw "Missing exclusion coverage: $expected" }
}
if ($targets.ContainsKey('C:') -or $targets.ContainsKey($PF)) { throw 'Broad system path excluded' }
Write-Host 'PASS: syntax, BOM, dry-run, NLM rules, Autodesk discovery and nested file coverage'
