param([ValidateSet('ru', 'en')][string]$Language = 'ru')
$Script:UiLanguage = $Language
$ErrorActionPreference = 'Stop'
$ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot 'RevitToolkit.ps1'), [ref]$null, [ref]$null)
foreach ($name in @('Get-UiText', 'Format-UiText', 'Test-AnimatedUi', 'Get-ToolkitLogo', 'Format-LogoRow', 'Show-Menu', 'Write-Bar')) {
    $f = $ast.Find({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name }, $true)
    . ([scriptblock]::Create($f.Extent.Text))
}
if ((Format-UiText 'abcdef' 5) -ne 'ab...') { throw 'Truncation failed' }
if ((Format-UiText 'abcdef' 2) -ne 'ab') { throw 'Narrow truncation failed' }
if ((Format-UiText "a`nb" 5) -ne 'a b') { throw 'Control character cleanup failed' }
$Script:Ctx = [pscustomobject]@{ Vt=$false; Width=50 }
$Script:C = @{ Accent=''; Cyan=''; Text=''; Muted=''; Reset=''; Bold='' }
$Script:G = @{ Prompt='>'; BarFull='#'; BarEmpty='.' }
function Test-InteractiveKeys { return $false }
function Write-Banner {}
function Write-Prompt {}
function Write-Blank {}
function Write-Rule {}
function Write-Meta {}
$Script:Answers = New-Object 'System.Collections.Generic.Queue[string]'
$Script:Answers.Enqueue('invalid'); $Script:Answers.Enqueue('a')
function Read-Host { return $Script:Answers.Dequeue() }
$items = @([pscustomobject]@{ Key='a'; Title='Autodesk'; Desc='Defender and network' })
if ((Show-Menu $items) -ne 'a') { throw 'Text menu selection failed' }
$Script:Answers.Enqueue('0')
if ((Show-Menu $items) -ne '0') { throw 'Text menu exit failed' }
if ((Show-Menu @()) -ne '0') { throw 'Empty menu failed' }
if (Test-AnimatedUi) { throw 'Animation must be disabled without VT' }
$Ascii = $true
$logo = @(Get-ToolkitLogo)
if ($logo.Count -ne 6 -or ($logo -join '') -match '[^\x20-\x7e]') { throw 'ASCII logo fallback failed' }
$Ascii = $false
if (@(Get-ToolkitLogo).Count -ne 6) { throw 'Large logo missing' }
$Script:Ctx.Vt = $true
$escape = [char]27
$Script:C.Cyan = "$escape[36m"; $Script:C.Text = "$escape[37m"
$Script:C.Blue = "$escape[34m"; $Script:C.Reset = "$escape[0m"
$frame1 = Format-LogoRow 'LOGO' -Phase 0
$frame2 = Format-LogoRow 'LOGO' -Phase 3
if ($frame1 -eq $frame2) { throw 'Logo animation frames do not change' }
if (($frame1 -replace '\x1b\[[0-9;]*m', '') -ne 'LOGO') { throw 'Animation changed logo characters' }
$NoAnimation = $true
if (Test-AnimatedUi) { throw 'NoAnimation flag ignored' }
$Script:Ctx.Vt = $false
$Script:C.Cyan = ''; $Script:C.Text = ''; $Script:C.Reset = ''
Write-Bar -Current -1 -Total 0 -Text 'negative'
Write-Bar -Current 200 -Total 100 -Text 'complete'
Write-Host 'PASS: text formatting, fallback menu, ASCII logo, animation frames/guard, progress bounds'
