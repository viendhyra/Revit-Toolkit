# Offline checks: no Defender or Firewall settings are changed.
$ErrorActionPreference = 'Stop'
$tokens = $null; $errors = $null
$path = Join-Path $PSScriptRoot 'RevitToolkit.ps1'
$ast = [Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw ($errors.Message -join "`n") }
$bytes = [IO.File]::ReadAllBytes($path)
if ($bytes[0] -ne 239 -or $bytes[1] -ne 187 -or $bytes[2] -ne 191) { throw 'UTF-8 BOM missing' }
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
Write-Host 'PASS: syntax, BOM, dry-run install/remove/firewall, unique rule names'
