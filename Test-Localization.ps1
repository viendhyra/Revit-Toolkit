# Tests use a temporary preference file and never execute maintenance modules.
$ErrorActionPreference = 'Stop'
$errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot 'RevitToolkit.ps1'), [ref]$null, [ref]$errors)
if ($errors.Count) { throw ($errors.Message -join "`n") }
foreach ($name in @('Get-UiText', 'Save-UiLanguage', 'Select-UiLanguage', 'Initialize-UiLanguage', 'Invoke-MainMenu')) {
    $f = $ast.Find({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name }, $true)
    . ([scriptblock]::Create($f.Extent.Text))
}
$calls = $ast.FindAll({ param($n) $n -is [Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'Get-UiText' }, $true)
if ($calls.Count -lt 300) { throw 'Incomplete translation coverage' }
foreach ($call in $calls) {
    if ($call.CommandElements.Count -ne 3) { throw "Invalid bilingual call: $($call.Extent.Text)" }
    if ($call.CommandElements[2].Value -match '[А-Яа-яЁё]') { throw "Russian text in English translation: $($call.Extent.Text)" }
}
$Script:UiLanguage = 'ru'
if ((Get-UiText 'Назад' 'Back') -ne 'Назад') { throw 'Russian selection failed' }
$Script:UiLanguage = 'en'
if ((Get-UiText 'Назад' 'Back') -ne 'Back') { throw 'English selection failed' }
$version = '2026'
if ((Get-UiText "Версия $version" "Version $version") -ne 'Version 2026') { throw 'Interpolation failed' }
function Write-Banner {}
function Write-Blank {}
function Write-Warn { param($Text) throw $Text }
$Script:LanguageFile = Join-Path ([IO.Path]::GetTempPath()) ('RevitToolkit-language-test-' + [guid]::NewGuid() + '.txt')
try {
    $Script:Answers = New-Object 'System.Collections.Generic.Queue[string]'
    $Script:Answers.Enqueue('invalid'); $Script:Answers.Enqueue('2')
    function Read-Host { return $Script:Answers.Dequeue() }
    Select-UiLanguage
    if ($Script:UiLanguage -ne 'en' -or (Get-Content $Script:LanguageFile) -ne 'en') { throw 'Selection/persistence failed' }
    $Language = ''
    $Script:UiLanguage = 'ru'
    Initialize-UiLanguage
    if ($Script:UiLanguage -ne 'en') { throw 'Saved language not restored' }
    $Language = 'ru'
    Initialize-UiLanguage
    if ($Script:UiLanguage -ne 'ru') { throw 'Explicit override failed' }
    if ((Get-Content $Script:LanguageFile) -ne 'en') { throw 'Session override changed preference' }
    $Script:MenuFrames = @()
    function Show-Menu {
        param($Items, $Title, $BackText)
        $Script:MenuFrames += $Items[4].Title
        if ($Script:MenuFrames.Count -eq 1) { return '9' }
        return '0'
    }
    function Invoke-SettingsMenu { $Script:UiLanguage = 'en' }
    Invoke-MainMenu
    if ($Script:MenuFrames.Count -ne 2 -or $Script:MenuFrames[0] -ne 'Очистка Revit' -or $Script:MenuFrames[1] -ne 'Revit cleanup') { throw 'Main menu did not refresh after language change' }
} finally {
    Remove-Item -LiteralPath $Script:LanguageFile -Force -ErrorAction SilentlyContinue
}
Write-Host "PASS: $($calls.Count) bilingual strings, selection, persistence, override, menu refresh"
