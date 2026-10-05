#Requires -Version 5.1
<#
.SYNOPSIS
    Revit Toolkit - единый терминальный хаб для обслуживания Autodesk Revit / Revit Server.

.DESCRIPTION
    Объединяет пять утилит в один скрипт с общим UI, логом и режимом сухого прогона:

      1. Установка IIS и компонентов для Revit Server (Windows Server)
      2. Настройка maxBytesPerRead в web.config Revit Server
      3. Менеджер переменных RSACCELERATOR<год>
      4. Полная очистка следов Revit (файлы + реестр) + обновление AdskLicensing
      5. Поиск и удаление backup-папок и журналов Revit
      6. Сводка окружения (что установлено, что настроено)

.PARAMETER Module
    Запуск конкретного модуля без меню: status | iis | maxbytes | accel | clean | backups | autodesk

.PARAMETER DryRun
    Сухой прогон: всё ищется и показывается, но ничего не удаляется и не меняется.

.PARAMETER Yes
    Не задавать подтверждений (для автоматизации). Использовать осознанно.

.PARAMETER NoColor
    Отключить ANSI-цвета.

.PARAMETER Ascii
    Заменить псевдографику на ASCII (для старых консолей и шрифтов без глифов).

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\RevitToolkit.ps1

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\RevitToolkit.ps1 -Module backups -DryRun

.NOTES
    Файл должен храниться в UTF-8 с BOM, иначе PowerShell 5.1 ломает кириллицу.
#>

[CmdletBinding()]
param(
    [ValidateSet('', 'status', 'iis', 'maxbytes', 'accel', 'clean', 'backups', 'autodesk')]
    [string]$Module = '',

    [switch]$DryRun,
    [switch]$Yes,
    [switch]$NoColor,
    [switch]$NoAnimation,
    [switch]$Ascii
)

$ErrorActionPreference = 'Stop'

# ============================================================================
#  БЛОК 0. Состояние и окружение
# ============================================================================

$Script:AppName    = 'Revit Toolkit'
$Script:AppVersion = '1.1.0'
$Script:Root       = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }

$Script:Ctx = [pscustomobject]@{
    DryRun    = [bool]$DryRun
    AssumeYes = [bool]$Yes
    IsAdmin   = $false
    LogPath   = $null
    Vt        = $false
    Width     = 78
}

function Initialize-Console {
    try {
        [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
        $global:OutputEncoding    = [System.Text.Encoding]::UTF8
    } catch { }

    try {
        $w = [Console]::WindowWidth
        if ($w -gt 40) { $Script:Ctx.Width = [Math]::Min($w - 2, 110) }
    } catch { }
}

function Enable-VirtualTerminal {
    if ($NoColor) { return $false }
    try { if ([Console]::IsOutputRedirected) { return $false } } catch { return $false }
    if ($env:WT_SESSION) { return $true }
    if ($Host.Name -eq 'Windows PowerShell ISE Host') { return $false }

    try {
        if (-not ('RtkNative.NativeConsole' -as [type])) {
            Add-Type -Namespace RtkNative -Name NativeConsole -MemberDefinition @'
[DllImport("kernel32.dll", SetLastError = true)]
public static extern IntPtr GetStdHandle(int nStdHandle);

[DllImport("kernel32.dll", SetLastError = true)]
public static extern bool GetConsoleMode(IntPtr hConsoleHandle, out uint lpMode);

[DllImport("kernel32.dll", SetLastError = true)]
public static extern bool SetConsoleMode(IntPtr hConsoleHandle, uint dwMode);
'@ | Out-Null
        }

        $handle = [RtkNative.NativeConsole]::GetStdHandle(-11)
        $mode = [uint32]0
        if (-not [RtkNative.NativeConsole]::GetConsoleMode($handle, [ref]$mode)) { return $false }
        return [RtkNative.NativeConsole]::SetConsoleMode($handle, ($mode -bor 0x0004))
    }
    catch { return $false }
}

function Test-IsAdministrator {
    try {
        $identity  = [Security.Principal.WindowsIdentity]::GetCurrent()
        $principal = New-Object Security.Principal.WindowsPrincipal($identity)
        return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    }
    catch { return $false }
}

function Test-IsWindowsServer {
    try {
        $os = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop
        return ($os.ProductType -ne 1)
    }
    catch { return $false }
}

# ============================================================================
#  БЛОК 1. UI: палитра, глифы, примитивы вывода
# ============================================================================

$Script:ESC = [char]27

function Initialize-Palette {
    $vt = $Script:Ctx.Vt
    $e = $Script:ESC

    function Seq([string]$code) { if ($vt) { $e + '[' + $code + 'm' } else { '' } }

    $Script:C = @{
        Reset  = Seq '0'
        Bold   = Seq '1'
        Dim    = Seq '2'
        Text   = Seq '38;2;232;230;227'
        Muted  = Seq '38;2;124;124;124'
        Faint  = Seq '38;2;92;92;92'
        Accent = Seq '38;2;217;119;87'
        Green  = Seq '38;2;86;196;127'
        Red    = Seq '38;2;240;95;85'
        Yellow = Seq '38;2;226;180;84'
        Cyan   = Seq '38;2;94;186;205'
        Blue   = Seq '38;2;120;160;230'
        Violet = Seq '38;2;177;146;224'
    }

    if ($Ascii) {
        $Script:G = @{
            Prompt = '>'; Bullet = '*'; Ok = 'OK'; Fail = 'X'; Warn = '!'
            Search = '?'; Dot = '.'; Bar = '-'; Sep = '-'; Arrow = '->'
            BarFull = '#'; BarEmpty = '.'
        }
    }
    else {
        $Script:G = @{
            Prompt = [char]0x25B8; Bullet = [char]0x25CF; Ok = [char]0x2713; Fail = [char]0x2717
            Warn = [char]0x26A0; Search = [char]0x2315; Dot = [char]0x00B7; Bar = [char]0x2500
            Sep = [char]0x2500; Arrow = [char]0x2192; BarFull = [char]0x2588; BarEmpty = [char]0x2591
        }
    }
}

function Write-Raw { param([string]$Text = '') Write-Host $Text }

function Write-Blank { Write-Host '' }

function Write-Rule {
    param([int]$Indent = 2)
    $len = [Math]::Max(10, $Script:Ctx.Width - $Indent - 2)
    Write-Host ((' ' * $Indent) + $Script:C.Faint + ([string]$Script:G.Bar * $len) + $Script:C.Reset)
}

function Write-Meta {
    param([string]$Text)
    Write-Host ("  " + $Script:C.Faint + $Text + $Script:C.Reset)
}

function Write-Prompt {
    param([string]$Text)
    Write-Host ''
    Write-Host ("  " + $Script:C.Accent + $Script:G.Prompt + $Script:C.Reset + ' ' + $Script:C.Bold + $Script:C.Text + $Text + $Script:C.Reset)
}

function Write-Bullet {
    param([string]$Text)
    Write-Host ("  " + $Script:C.Accent + $Script:G.Bullet + $Script:C.Reset + ' ' + $Script:C.Text + $Text + $Script:C.Reset)
    Write-Log "  * $Text"
}

function Write-Tool {
    param([string]$Action, [string]$Target)
    Write-Host ("  " + $Script:C.Faint + $Script:G.Search + ' ' + $Action + ' ' + $Target + $Script:C.Reset)
    Write-Log "  ~ $Action $Target"
}

function Write-Add {
    param([string]$Text)
    Write-Host ("  " + $Script:C.Green + '+ ' + $Text + $Script:C.Reset)
    Write-Log "  + $Text"
}

function Write-Del {
    param([string]$Text)
    Write-Host ("  " + $Script:C.Red + '- ' + $Text + $Script:C.Reset)
    Write-Log "  - $Text"
}

function Write-Ok {
    param([string]$Text)
    Write-Host ("  " + $Script:C.Green + $Script:G.Ok + ' ' + $Text + $Script:C.Reset)
    Write-Log "  OK $Text"
}

function Write-Fail {
    param([string]$Text)
    Write-Host ("  " + $Script:C.Red + $Script:G.Fail + ' ' + $Text + $Script:C.Reset)
    Write-Log "  FAIL $Text"
}

function Write-Warn {
    param([string]$Text)
    Write-Host ("  " + $Script:C.Yellow + $Script:G.Warn + ' ' + $Text + $Script:C.Reset)
    Write-Log "  WARN $Text"
}

function Write-Info {
    param([string]$Text)
    Write-Host ("  " + $Script:C.Muted + $Text + $Script:C.Reset)
    Write-Log "  $Text"
}

function Write-Kv {
    param([string]$Key, [string]$Value, [string]$Color = '')
    $c = if ($Color) { $Color } else { $Script:C.Text }
    Write-Host ("  " + $Script:C.Muted + ("{0,-26}" -f $Key) + $Script:C.Reset + $c + $Value + $Script:C.Reset)
}

function Write-Bar {
    param([int]$Current, [int]$Total, [string]$Text = '')
    $Total = [Math]::Max(1, $Total)
    $pct = [Math]::Max(0, [Math]::Min(100, [int](100.0 * $Current / $Total)))
    $cells = [Math]::Max(4, [Math]::Min(28, $Script:Ctx.Width - 24))
    $full = [int][Math]::Floor($cells * $pct / 100)
    $bar = ([string]$Script:G.BarFull * $full) + ([string]$Script:G.BarEmpty * ($cells - $full))
    $label = Format-UiText $Text ([Math]::Max(1, $Script:Ctx.Width - $cells - 14))
    $line = '  ' + $Script:C.Cyan + $bar + $Script:C.Reset + $Script:C.Text + ("  {0,3}%  {1}" -f $pct, $label) + $Script:C.Reset
    if (Test-InteractiveKeys) {
        $erase = if ($Script:Ctx.Vt) { "$($Script:ESC)[K" } else { ' ' * 8 }
        Write-Host ("`r" + $line + $erase) -NoNewline
        if ($Current -ge $Total) { Write-Host '' }
    } else { Write-Host $line }
}

function Test-AnimatedUi {
    if ($NoAnimation -or $Ascii -or $NoColor -or -not $Script:Ctx.Vt) { return $false }
    try { return (-not [Console]::IsOutputRedirected -and (Test-InteractiveKeys)) }
    catch { return $false }
}

function Format-UiText {
    param([string]$Text, [int]$Width)
    $Width = [Math]::Max(1, $Width)
    $Text = $Text -replace '[\x00-\x1f\x7f]', ' '
    if ($Text.Length -le $Width) { return $Text }
    if ($Width -le 3) { return $Text.Substring(0, $Width) }
    return $Text.Substring(0, $Width - 3) + '...'
}

function Show-StartupAnimation {
    if (-not (Test-AnimatedUi)) { return }
    Write-Banner
    $frames = @('[     ]', '[=    ]', '[==   ]', '[===  ]', '[==== ]', '[=====]')
    foreach ($frame in $frames) {
        Write-Host ("`r  " + $Script:C.Cyan + $frame + '  REVIT TOOLKIT / READY' + $Script:C.Reset) -NoNewline
        Start-Sleep -Milliseconds 45
    }
    Write-Host ''
}

function Write-Banner {
    if ($Script:Ctx.Vt -and (Test-InteractiveKeys)) {
        Write-Host ("$($Script:ESC)[H$($Script:ESC)[J") -NoNewline
    } else { Clear-Host }
    try {
        if ([Console]::WindowWidth -gt 20) { $Script:Ctx.Width = [Math]::Min([Console]::WindowWidth - 2, 110) }
    } catch { }
    $width = $Script:Ctx.Width - 4
    $mode = if ($Script:Ctx.DryRun) { 'DRY RUN' } else { 'LIVE' }
    $rights = if ($Script:Ctx.IsAdmin) { 'ADMIN' } else { 'USER' }
    Write-Blank
    Write-Host ('  ' + $Script:C.Bold + $Script:C.Cyan + (Format-UiText "R / T   REVIT TOOLKIT   v$Script:AppVersion" $width) + $Script:C.Reset)
    Write-Host ('  ' + $Script:C.Muted + (Format-UiText "AUTODESK SYSTEM CONSOLE   /   $env:COMPUTERNAME" $width) + $Script:C.Reset)
    $color = if ($Script:Ctx.DryRun) { $Script:C.Violet } else { $Script:C.Yellow }
    Write-Host ('  ' + $color + "[$mode]" + $Script:C.Reset + $Script:C.Muted + "  [$rights]  PS $($PSVersionTable.PSVersion)" + $Script:C.Reset)
    Write-Rule
}

# ============================================================================
#  БЛОК 2. Лог
# ============================================================================

function Initialize-Log {
    $candidates = @(
        (Join-Path $env:ProgramData 'RevitToolkit\logs'),
        (Join-Path $env:LOCALAPPDATA 'RevitToolkit\logs'),
        (Join-Path $Script:Root 'logs')
    )

    foreach ($dir in $candidates) {
        try {
            if (-not (Test-Path -LiteralPath $dir)) {
                New-Item -ItemType Directory -Path $dir -Force -ErrorAction Stop | Out-Null
            }
            $file = Join-Path $dir ("RevitToolkit-{0}.log" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
            Set-Content -LiteralPath $file -Value '' -Encoding UTF8 -ErrorAction Stop
            $Script:Ctx.LogPath = $file
            break
        }
        catch { continue }
    }
}

function Write-Log {
    param([string]$Text)
    if (-not $Script:Ctx.LogPath) { return }
    try {
        $stamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
        Add-Content -LiteralPath $Script:Ctx.LogPath -Value "$stamp  $Text" -Encoding UTF8 -ErrorAction SilentlyContinue
    }
    catch { }
}

function Write-LogHeader {
    param([string]$Title)
    Write-Log ''
    Write-Log "=========== $Title ==========="
}

# ============================================================================
#  БЛОК 3. Ввод: меню со стрелками, подтверждения, выбор из списка
# ============================================================================

function Test-InteractiveKeys {
    if ($Host.Name -eq 'Windows PowerShell ISE Host') { return $false }
    try { $null = [Console]::KeyAvailable; return $true } catch { return $false }
}

function Show-Menu {
    param(
        [Parameter(Mandatory = $true)] [AllowEmptyCollection()] [array]$Items,
        [string]$Title = '',
        [string]$BackText = 'Выход'
    )
    if (-not $Items.Count) { return '0' }
    $index = 0
    $useKeys = Test-InteractiveKeys
    $firstFrame = $true
    $animated = Test-AnimatedUi
    $cursorVisible = $true
    try {
        if ($animated) {
            $cursorVisible = [Console]::CursorVisible
            [Console]::CursorVisible = $false
        }
        while ($true) {
            Write-Banner
            Write-Prompt $Title
            Write-Blank
            # Scroll a compact viewport so large submenus also fit small terminals.
            $rows = $Items.Count
            if ($useKeys) {
                try { $rows = [Math]::Max(1, [Math]::Min($Items.Count, [Console]::WindowHeight - 16)) } catch { }
            }
            $start = [Math]::Max(0, [Math]::Min($index - [int]($rows / 2), $Items.Count - $rows))
            for ($i = $start; $i -lt $start + $rows; $i++) {
                $item = $Items[$i]
                $selected = ($i -eq $index)
                $marker = if ($selected) { [string]$Script:G.Prompt } else { ' ' }
                $label = Format-UiText ("{0}  [{1}]  {2}" -f $marker, $item.Key, $item.Title) ($Script:Ctx.Width - 6)
                if ($selected) {
                    $background = if ($Script:Ctx.Vt) { "$($Script:ESC)[48;2;24;44;58m" } else { '' }
                    Write-Host ('  ' + $background + $Script:C.Cyan + $Script:C.Bold + $label.PadRight($Script:Ctx.Width - 4) + $Script:C.Reset)
                } else {
                    Write-Host ('  ' + $Script:C.Muted + $label + $Script:C.Reset)
                }
                if ($firstFrame -and $animated) { Start-Sleep -Milliseconds 12 }
            }
            Write-Blank
            Write-Rule
            Write-Host ('  ' + $Script:C.Text + (Format-UiText $Items[$index].Desc ($Script:Ctx.Width - 4)) + $Script:C.Reset)
            if ($rows -lt $Items.Count) { Write-Meta ("{0}/{1}  ·  остальные пункты: стрелки" -f ($index + 1), $Items.Count) }
            Write-Blank
            Write-Meta "0  $BackText   /   стрелки + Enter   /   клавиша пункта"
            $firstFrame = $false
            if (-not $useKeys) {
                $answer = (Read-Host '  Выбор').Trim()
                if ($answer -eq '0') { return '0' }
                $hit = $Items | Where-Object { $_.Key -eq $answer } | Select-Object -First 1
                if ($hit) { return $hit.Key }
                continue
            }
            $key = [Console]::ReadKey($true)
            switch ($key.Key) {
                'UpArrow' { $index = ($index - 1 + $Items.Count) % $Items.Count }
                'DownArrow' { $index = ($index + 1) % $Items.Count }
                'Home' { $index = 0 }
                'End' { $index = $Items.Count - 1 }
                'Enter' { return $Items[$index].Key }
                'Escape' { return '0' }
                'Q' { return '0' }
                default {
                    $ch = [string]$key.KeyChar
                    if ($ch -eq '0') { return '0' }
                    $hit = $Items | Where-Object { $_.Key -eq $ch } | Select-Object -First 1
                    if ($hit) { return $hit.Key }
                }
            }
        }
    } finally {
        if ($animated) { try { [Console]::CursorVisible = $cursorVisible } catch { } }
    }
}

function Confirm-Action {
    param(
        [Parameter(Mandatory = $true)] [string]$Question,
        [switch]$Danger
    )

    if ($Script:Ctx.AssumeYes) {
        Write-Info "$Question -> да (режим -Yes)"
        return $true
    }

    if ($Script:Ctx.DryRun) {
        Write-Info "$Question -> пропуск (сухой прогон)"
        return $false
    }

    $color = if ($Danger) { $Script:C.Red } else { $Script:C.Yellow }
    Write-Host ''
    Write-Host ("  " + $color + $Script:G.Warn + ' ' + $Question + $Script:C.Reset + $Script:C.Faint + '  [y/n]' + $Script:C.Reset) -NoNewline
    $answer = Read-Host
    return ($answer -match '^(y|yes|д|да)$')
}

function Read-Text {
    param(
        [Parameter(Mandatory = $true)] [string]$Label,
        [string]$Hint = ''
    )
    Write-Host ''
    if ($Hint) { Write-Host ("  " + $Script:C.Faint + $Hint + $Script:C.Reset) }
    Write-Host ("  " + $Script:C.Accent + $Script:G.Prompt + $Script:C.Reset + ' ' + $Script:C.Text + $Label + $Script:C.Reset) -NoNewline
    $value = Read-Host
    if ($null -eq $value) { return '' }
    return $value.Trim()
}

function Read-Selection {
    <#
        Множественный выбор из массива строк.
        Возвращает массив индексов (0-based).
    #>
    param(
        [Parameter(Mandatory = $true)] [array]$Options,
        [string]$Title = 'Выберите позиции'
    )

    Write-Blank
    Write-Bullet $Title
    Write-Blank
    for ($i = 0; $i -lt $Options.Count; $i++) {
        Write-Host ("    " + $Script:C.Muted + ("[{0}]" -f ($i + 1)) + $Script:C.Reset + ' ' + $Script:C.Text + $Options[$i] + $Script:C.Reset)
    }
    Write-Host ("    " + $Script:C.Muted + "[A]" + $Script:C.Reset + ' ' + $Script:C.Text + 'Все' + $Script:C.Reset)

    $raw = Read-Text -Label 'Номера через запятую или A'
    if ([string]::IsNullOrWhiteSpace($raw)) { return @() }
    if ($raw.ToUpper() -eq 'A') { return 0..($Options.Count - 1) }

    $result = @()
    foreach ($part in ($raw -split ',')) {
        $n = 0
        if ([int]::TryParse($part.Trim(), [ref]$n)) {
            $idx = $n - 1
            if ($idx -ge 0 -and $idx -lt $Options.Count -and ($result -notcontains $idx)) { $result += $idx }
        }
    }
    return $result
}

function Wait-Menu {
    Write-Host ''
    Write-Host ("  " + $Script:C.Faint + "Enter $($Script:G.Arrow) вернуться в меню" + $Script:C.Reset) -NoNewline
    Read-Host | Out-Null
}

function Invoke-Step {
    <#
        Выполняет блок с отметкой времени в стиле "$ команда / ✓ done in 1.2s".
    #>
    param(
        [Parameter(Mandatory = $true)] [string]$Text,
        [Parameter(Mandatory = $true)] [scriptblock]$Action,
        [switch]$Quiet
    )

    Write-Host ("  " + $Script:C.Faint + '$ ' + $Text + $Script:C.Reset)
    Write-Log "  $ $Text"

    $sw = [Diagnostics.Stopwatch]::StartNew()
    try {
        $result = & $Action
        $sw.Stop()
        if (-not $Quiet) { Write-Ok ("готово за {0:N1}s" -f $sw.Elapsed.TotalSeconds) }
        return $result
    }
    catch {
        $sw.Stop()
        Write-Fail ("ошибка: " + $_.Exception.Message)
        Write-Log "  EXCEPTION $($_.Exception.ToString())"
        return $null
    }
}

function Test-DryRun {
    param([string]$What)
    if ($Script:Ctx.DryRun) {
        Write-Host ("  " + $Script:C.Violet + "[dry-run] " + $Script:C.Reset + $Script:C.Muted + $What + $Script:C.Reset)
        Write-Log "  [dry-run] $What"
        return $true
    }
    return $false
}

function Assert-Admin {
    param([string]$Reason = 'Модуль требует прав администратора.')
    if ($Script:Ctx.IsAdmin) { return $true }

    Write-Blank
    Write-Fail $Reason
    Write-Info 'Перезапустите PowerShell от имени администратора:'
    Write-Host ("  " + $Script:C.Faint + "  Start-Process powershell -Verb RunAs" + $Script:C.Reset)
    return $false
}

# ============================================================================
#  БЛОК 4. Общие функции обнаружения Revit / Revit Server
# ============================================================================

function Get-NormalizedText {
    param([string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return '' }
    return ($Text -replace '\s+', ' ').Trim()
}

function Get-UninstallEntry {
    $roots = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall',
        'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall',
        'HKCU:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall'
    )

    foreach ($root in $roots) {
        if (-not (Test-Path -LiteralPath $root)) { continue }
        Get-ChildItem -LiteralPath $root -ErrorAction SilentlyContinue | ForEach-Object {
            $props = Get-ItemProperty -LiteralPath $_.PSPath -ErrorAction SilentlyContinue
            $name = Get-NormalizedText $props.DisplayName
            if ($name -match 'Revit') {
                [pscustomobject]@{
                    DisplayName    = $name
                    DisplayVersion = Get-NormalizedText $props.DisplayVersion
                    RegistryPath   = $_.PSPath
                }
            }
        }
    }
}

function Get-DetectedRevitVersion {
    $versions = New-Object System.Collections.Generic.HashSet[string]

    Get-UninstallEntry | ForEach-Object {
        $text = "$($_.DisplayName) $($_.DisplayVersion)"
        [regex]::Matches($text, '\b20\d{2}\b') | ForEach-Object { [void]$versions.Add($_.Value) }
    }

    $patterns = @(
        'C:\Program Files\Autodesk\Revit *',
        'C:\Program Files\Autodesk\Autodesk Revit *',
        'C:\ProgramData\Autodesk\RVT *',
        "$env:APPDATA\Autodesk\Revit\Autodesk Revit *",
        "$env:LOCALAPPDATA\Autodesk\Revit\Autodesk Revit *"
    )

    foreach ($pattern in $patterns) {
        Get-ChildItem -Path $pattern -ErrorAction SilentlyContinue | ForEach-Object {
            [regex]::Matches($_.FullName, '\b20\d{2}\b') | ForEach-Object { [void]$versions.Add($_.Value) }
        }
    }

    return @($versions | Sort-Object)
}

function Get-RevitServerInstall {
    $base = 'C:\Program Files\Autodesk'
    if (-not (Test-Path -LiteralPath $base)) { return @() }

    return @(Get-ChildItem -LiteralPath $base -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -like 'Revit Server*' } |
        Sort-Object Name)
}

function Get-RevitServerConfigFile {
    param([Parameter(Mandatory = $true)] $ServerFolder)

    $files = @(
        (Join-Path $ServerFolder.FullName 'Services\ModelService\web.config'),
        (Join-Path $ServerFolder.FullName 'Services\LocalService\web.config'),
        (Join-Path $ServerFolder.FullName 'Services\AdminService\web.config')
    )

    return @($files | Where-Object { Test-Path -LiteralPath $_ })
}

function Get-MaxBytesPerRead {
    param([Parameter(Mandatory = $true)] [string]$ConfigPath)
    try {
        $content = Get-Content -LiteralPath $ConfigPath -Raw -ErrorAction Stop
        $match = [regex]::Match($content, 'maxBytesPerRead\s*=\s*"(\d+)"')
        if ($match.Success) { return $match.Groups[1].Value }
        return $null
    }
    catch { return $null }
}

function Get-RevitServerService {
    return @(Get-Service -ErrorAction SilentlyContinue | Where-Object {
        $_.DisplayName -like '*Revit Server*' -or $_.Name -like '*RevitServer*'
    })
}

$Script:AcceleratorVersions = 2018..2026

function Get-AcceleratorValue {
    param([Parameter(Mandatory = $true)] [int]$Version)
    return [Environment]::GetEnvironmentVariable("RSACCELERATOR$Version", 'User')
}

# ============================================================================
#  МОДУЛЬ: Сводка окружения
# ============================================================================

function Invoke-ModuleStatus {
    Write-Banner
    Write-Prompt 'сводка окружения'
    Write-LogHeader 'STATUS'

    Write-Blank
    Write-Bullet 'Система'
    try {
        $os = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop
        Write-Kv 'ОС' "$($os.Caption) ($($os.Version))"
    }
    catch { Write-Kv 'ОС' 'не определена' $Script:C.Yellow }
    Write-Kv 'Тип' $(if (Test-IsWindowsServer) { 'Windows Server' } else { 'Клиентская Windows' })
    Write-Kv 'PowerShell' $PSVersionTable.PSVersion.ToString()
    Write-Kv 'Права' $(if ($Script:Ctx.IsAdmin) { 'администратор' } else { 'обычный пользователь' }) $(if ($Script:Ctx.IsAdmin) { $Script:C.Green } else { $Script:C.Yellow })
    Write-Kv 'Лог сессии' $(if ($Script:Ctx.LogPath) { $Script:Ctx.LogPath } else { 'не пишется' })

    Write-Blank
    Write-Bullet 'Установленные версии Revit'
    $versions = @(Invoke-Step -Text 'scan registry + program files' -Action { Get-DetectedRevitVersion } -Quiet)
    if ($versions.Count -eq 0) {
        Write-Info 'не найдено'
    }
    else {
        foreach ($v in $versions) {
            $accel = Get-AcceleratorValue -Version ([int]$v)
            $accelText = if ([string]::IsNullOrWhiteSpace($accel)) { 'accelerator не задан' } else { "accelerator: $accel" }
            Write-Kv "Revit $v" $accelText $(if ($accel) { $Script:C.Green } else { $Script:C.Muted })
        }
    }

    Write-Blank
    Write-Bullet 'Revit Server'
    $servers = @(Get-RevitServerInstall)
    if ($servers.Count -eq 0) {
        Write-Info 'не установлен'
    }
    else {
        foreach ($server in $servers) {
            $configs = @(Get-RevitServerConfigFile -ServerFolder $server)
            $values = @()
            foreach ($config in $configs) {
                $value = Get-MaxBytesPerRead -ConfigPath $config
                if ($value) { $values += $value }
            }
            $valueText = if ($values.Count -eq 0) { 'maxBytesPerRead не найден' } else { 'maxBytesPerRead: ' + (($values | Sort-Object -Unique) -join ' / ') }
            Write-Kv $server.Name $valueText
        }

        $services = @(Get-RevitServerService)
        foreach ($svc in $services) {
            $color = if ($svc.Status -eq 'Running') { $Script:C.Green } else { $Script:C.Yellow }
            Write-Kv "  $($svc.Name)" $svc.Status $color
        }
    }

    if (Test-IsWindowsServer) {
        Write-Blank
        Write-Bullet 'Компоненты IIS для Revit Server'
        $required = Get-IisFeatureList
        try {
            Import-Module ServerManager -ErrorAction Stop
            $state = Get-WindowsFeature -Name $required -ErrorAction Stop
            $missing = @($state | Where-Object { $_.InstallState -ne 'Installed' })
            if ($missing.Count -eq 0) {
                Write-Ok "все $($required.Count) компонентов включены"
            }
            else {
                Write-Warn "не включено: $($missing.Count) из $($required.Count)"
                foreach ($item in $missing) { Write-Kv "  $($item.Name)" $item.InstallState $Script:C.Yellow }
            }
        }
        catch { Write-Info 'не удалось прочитать состояние ролей' }
    }

    Wait-Menu
}

# ============================================================================
#  МОДУЛЬ 1: Установка IIS для Revit Server
#  (Install_RevitServer_IIS)
# ============================================================================

function Get-IisFeatureList {
    return @(
        'Web-Server',
        'NET-Framework-45-Features',
        'Web-Asp-Net45',
        'NET-WCF-HTTP-Activation45',
        'NET-WCF-TCP-Activation45',
        'Web-ASP',
        'Web-CGI',
        'Web-Includes',
        'Web-Mgmt-Compat',
        'Web-Metabase',
        'Web-Lgcy-Scripting',
        'Web-WMI'
    )
}

function Invoke-ModuleIis {
    Write-Banner
    Write-Prompt 'установка IIS и компонентов для Revit Server'
    Write-LogHeader 'IIS INSTALL'

    if (-not (Test-IsWindowsServer)) {
        Write-Blank
        Write-Fail 'Это не Windows Server. Модуль использует Install-WindowsFeature и работает только на серверной ОС.'
        Write-Info 'На клиентской Windows компоненты IIS ставятся через Enable-WindowsOptionalFeature / DISM.'
        Wait-Menu
        return
    }

    if (-not (Assert-Admin -Reason 'Установка ролей Windows требует прав администратора.')) { Wait-Menu; return }

    $features = Get-IisFeatureList
    Import-Module ServerManager -ErrorAction SilentlyContinue

    Write-Blank
    Write-Tool 'reading' 'состояние ролей Windows Server'

    $before = $null
    try { $before = Get-WindowsFeature -Name $features -ErrorAction Stop }
    catch {
        Write-Fail "не удалось прочитать список ролей: $($_.Exception.Message)"
        Wait-Menu
        return
    }

    Write-Blank
    Write-Bullet 'Состояние ДО установки'
    Write-Blank
    foreach ($item in $before) {
        $color = if ($item.InstallState -eq 'Installed') { $Script:C.Green } else { $Script:C.Muted }
        Write-Kv $item.Name ([string]$item.InstallState) $color
    }

    $missing = @($before | Where-Object { $_.InstallState -ne 'Installed' })

    Write-Blank
    if ($missing.Count -eq 0) {
        Write-Ok 'все требуемые компоненты уже включены, установка не нужна'
        Write-Blank
        if (Confirm-Action -Question 'Всё равно перезапустить IIS (iisreset)?') {
            Invoke-Step -Text 'iisreset' -Action { iisreset | ForEach-Object { Write-Log "     $_" } } | Out-Null
        }
        Wait-Menu
        return
    }

    Write-Bullet "Будет включено компонентов: $($missing.Count)"
    Write-Blank
    foreach ($item in $missing) { Write-Add "$($item.Name)  $($Script:G.Dot)  $($item.DisplayName)" }

    Write-Blank
    if (Test-DryRun "Install-WindowsFeature -Name $($missing.Name -join ', ') -IncludeManagementTools") {
        Wait-Menu
        return
    }

    if (-not (Confirm-Action -Question 'Запустить установку компонентов?')) {
        Write-Info 'Отменено.'
        Wait-Menu
        return
    }

    Write-Blank
    $result = Invoke-Step -Text 'Install-WindowsFeature -IncludeManagementTools' -Action {
        $output = Install-WindowsFeature -Name $features -IncludeManagementTools -ErrorAction Stop
        $output
    }

    if ($null -eq $result) {
        Write-Fail 'Установка завершилась с ошибкой. Перезагрузка не выполняется.'
        Wait-Menu
        return
    }

    Write-Blank
    Write-Bullet 'Состояние ПОСЛЕ установки'
    Write-Blank
    $after = Get-WindowsFeature -Name $features -ErrorAction SilentlyContinue
    $stillMissing = @()
    foreach ($item in $after) {
        if ($item.InstallState -eq 'Installed') {
            Write-Ok "$($item.Name)"
        }
        else {
            Write-Fail "$($item.Name)  $($Script:G.Arrow)  $($item.InstallState)"
            $stillMissing += $item
        }
    }

    Write-Blank
    if ($stillMissing.Count -gt 0) {
        Write-Warn "Не включено компонентов: $($stillMissing.Count). Перезагрузка не выполняется автоматически."
        Wait-Menu
        return
    }

    Write-Ok 'Все требуемые компоненты включены'

    Write-Blank
    Invoke-Step -Text 'iisreset' -Action { iisreset | ForEach-Object { Write-Log "     $_" } } | Out-Null

    Write-Blank
    if ($result.RestartNeeded -eq 'Yes' -or $result.RestartNeeded -eq $true) {
        Write-Warn 'Windows сообщает, что требуется перезагрузка.'
    }

    if (Confirm-Action -Question 'Перезагрузить сервер через 60 секунд?' -Danger) {
        Write-Info 'Отменить можно командой: shutdown /a'
        shutdown.exe /r /t 60 /c "Revit Toolkit: IIS-компоненты для Revit Server установлены."
        Write-Ok 'Перезагрузка запланирована'
    }
    else {
        Write-Info 'Перезагрузите сервер вручную, чтобы компоненты применились.'
    }

    Wait-Menu
}

# ============================================================================
#  МОДУЛЬ 2: maxBytesPerRead в web.config Revit Server
#  (RevitServer-MaxBytesPerRead-Fix)
# ============================================================================

function Invoke-ModuleMaxBytes {
    Write-Banner
    Write-Prompt 'настройка maxBytesPerRead в Revit Server'
    Write-LogHeader 'MAXBYTESPERREAD'

    Write-Blank
    Write-Tool 'reading' 'C:\Program Files\Autodesk\Revit Server*'

    $servers = @(Get-RevitServerInstall)
    if ($servers.Count -eq 0) {
        Write-Blank
        Write-Fail 'Revit Server не найден.'
        Wait-Menu
        return
    }

    Write-Blank
    Write-Bullet "Найдено установок: $($servers.Count)"
    Write-Blank

    $labels = @()
    foreach ($server in $servers) {
        $configs = @(Get-RevitServerConfigFile -ServerFolder $server)
        $values = @()
        foreach ($config in $configs) {
            $value = Get-MaxBytesPerRead -ConfigPath $config
            if ($value) { $values += $value }
        }
        $valueText = if ($values.Count -eq 0) { 'значение не найдено' } else { (($values | Sort-Object -Unique) -join ' / ') }
        $labels += ("{0}   [web.config: {1}, maxBytesPerRead: {2}]" -f $server.Name, $configs.Count, $valueText)
    }

    $selected = Read-Selection -Options $labels -Title 'Какие версии обрабатывать'
    if ($selected.Count -eq 0) {
        Write-Blank
        Write-Info 'Ничего не выбрано.'
        Wait-Menu
        return
    }

    $modes = @(
        [pscustomobject]@{ Key = '1'; Title = 'Установить 102400'; Desc = 'Рекомендуется для больших моделей и медленных каналов' },
        [pscustomobject]@{ Key = '2'; Title = 'Вернуть значение Autodesk 4096'; Desc = 'Откат к стандартной конфигурации' },
        [pscustomobject]@{ Key = '3'; Title = 'Своё значение'; Desc = 'Ввести число вручную' }
    )

    $modeKey = Show-Menu -Items $modes -Title 'режим изменения' -BackText 'Отмена'
    if ($modeKey -eq '0') { return }

    $newValue = switch ($modeKey) {
        '1' { '102400' }
        '2' { '4096' }
        '3' {
            $raw = Read-Text -Label 'Значение maxBytesPerRead' -Hint 'Целое число, например 65536'
            if ($raw -notmatch '^\d+$') { $null } else { $raw }
        }
    }

    if (-not $newValue) {
        Write-Blank
        Write-Fail 'Некорректное значение.'
        Wait-Menu
        return
    }

    if (-not (Assert-Admin -Reason 'Изменение web.config и остановка служб требуют прав администратора.')) { Wait-Menu; return }

    Write-Banner
    Write-Prompt "maxBytesPerRead $($Script:G.Arrow) $newValue"
    Write-Blank

    $targets = @()
    foreach ($idx in $selected) {
        $server = $servers[$idx]
        foreach ($config in (Get-RevitServerConfigFile -ServerFolder $server)) {
            $current = Get-MaxBytesPerRead -ConfigPath $config
            $targets += [pscustomobject]@{
                Server  = $server.Name
                Path    = $config
                Current = $current
            }
        }
    }

    Write-Bullet "Файлов к изменению: $($targets.Count)"
    Write-Blank
    foreach ($target in $targets) {
        $currentText = if ($target.Current) { $target.Current } else { 'нет параметра' }
        Write-Tool 'reading' $target.Path
        Write-Del "maxBytesPerRead=`"$currentText`""
        Write-Add "maxBytesPerRead=`"$newValue`""
    }

    Write-Blank
    if (Test-DryRun "изменение $($targets.Count) файлов + перезапуск служб Revit Server") { Wait-Menu; return }
    if (-not (Confirm-Action -Question "Остановить службы Revit Server и изменить $($targets.Count) файлов?" -Danger)) {
        Write-Info 'Отменено.'
        Wait-Menu
        return
    }

    Write-Blank
    $services = @(Get-RevitServerService)
    $wasRunning = @($services | Where-Object { $_.Status -eq 'Running' })

    Invoke-Step -Text "stop services ($($wasRunning.Count))" -Action {
        foreach ($svc in $wasRunning) {
            try {
                Stop-Service -Name $svc.Name -Force -ErrorAction Stop
                Write-Log "     stopped $($svc.Name)"
            }
            catch { Write-Log "     ERROR stop $($svc.Name): $($_.Exception.Message)" }
        }
    } | Out-Null

    $changed = 0
    $failed = 0

    foreach ($target in $targets) {
        try {
            Copy-Item -LiteralPath $target.Path -Destination "$($target.Path).bak" -Force -ErrorAction Stop

            $content = Get-Content -LiteralPath $target.Path -Raw -ErrorAction Stop
            if ($content -match 'maxBytesPerRead\s*=\s*"\d+"') {
                $updated = [regex]::Replace($content, 'maxBytesPerRead\s*=\s*"\d+"', "maxBytesPerRead=`"$newValue`"")
                Set-Content -LiteralPath $target.Path -Value $updated -Encoding UTF8 -ErrorAction Stop
                $changed++
                Write-Ok "$($target.Server)  $($Script:G.Dot)  $(Split-Path $target.Path -Leaf)  $($Script:G.Dot)  backup: .bak"
            }
            else {
                Write-Warn "параметр не найден: $($target.Path)"
            }
        }
        catch {
            $failed++
            Write-Fail "$($target.Path)  $($Script:G.Dot)  $($_.Exception.Message)"
        }
    }

    Write-Blank
    Invoke-Step -Text "start services ($($wasRunning.Count))" -Action {
        foreach ($svc in $wasRunning) {
            try {
                Start-Service -Name $svc.Name -ErrorAction Stop
                Write-Log "     started $($svc.Name)"
            }
            catch { Write-Log "     ERROR start $($svc.Name): $($_.Exception.Message)" }
        }
    } | Out-Null

    Write-Blank
    Write-Bullet "Изменено файлов: $changed, ошибок: $failed"
    if ($changed -gt 0) {
        Write-Info 'Резервные копии лежат рядом с web.config с расширением .bak'
    }

    Wait-Menu
}

# ============================================================================
#  МОДУЛЬ 3: Менеджер RSACCELERATOR
#  (Revit_RS_Accelerator_Manager)
# ============================================================================

function Set-AcceleratorValue {
    param([int]$Version, [string]$Address)
    [Environment]::SetEnvironmentVariable("RSACCELERATOR$Version", $Address, 'User')
}

function Remove-AcceleratorValue {
    param([int]$Version)
    [Environment]::SetEnvironmentVariable("RSACCELERATOR$Version", $null, 'User')
}

function Update-EnvironmentBroadcast {
    try {
        if (-not ('RtkNative.EnvironmentNotifier' -as [type])) {
            Add-Type -Namespace RtkNative -Name EnvironmentNotifier -MemberDefinition @'
[DllImport("user32.dll", SetLastError = true, CharSet = CharSet.Auto)]
public static extern IntPtr SendMessageTimeout(
    IntPtr hWnd, uint Msg, UIntPtr wParam, string lParam,
    uint fuFlags, uint uTimeout, out UIntPtr lpdwResult);
'@ | Out-Null
        }

        $result = [UIntPtr]::Zero
        [RtkNative.EnvironmentNotifier]::SendMessageTimeout(
            [IntPtr]0xffff, 0x1A, [UIntPtr]::Zero, 'Environment', 0x0002, 5000, [ref]$result) | Out-Null
        return $true
    }
    catch { return $false }
}

function Test-AcceleratorAddress {
    param([string]$Address)
    return ($Address.Trim().Length -gt 0 -and $Address -match '^[a-zA-Z0-9._:-]+$')
}

function Show-AcceleratorTable {
    Write-Blank
    Write-Bullet 'Текущие значения RSACCELERATOR'
    Write-Blank
    foreach ($version in $Script:AcceleratorVersions) {
        $value = Get-AcceleratorValue -Version $version
        if ([string]::IsNullOrWhiteSpace($value)) {
            Write-Kv "RSACCELERATOR$version" 'не задано' $Script:C.Faint
        }
        else {
            Write-Kv "RSACCELERATOR$version" $value $Script:C.Green
        }
    }
}

function Select-RevitVersionForAccelerator {
    $options = @()
    foreach ($version in $Script:AcceleratorVersions) {
        $value = Get-AcceleratorValue -Version $version
        $status = if ([string]::IsNullOrWhiteSpace($value)) { 'не задано' } else { $value }
        $options += ("Revit {0}   [{1}]" -f $version, $status)
    }

    $selected = Read-Selection -Options $options -Title 'Выберите версии Revit'
    $result = @()
    foreach ($idx in $selected) { $result += [int]$Script:AcceleratorVersions[$idx] }
    return $result
}

function Read-AcceleratorAddress {
    while ($true) {
        $address = Read-Text -Label 'Адрес акселератора' -Hint 'Например: 192.168.88.21 или revit-accel.company.local'
        if (Test-AcceleratorAddress -Address $address) { return $address }
        Write-Fail 'Адрес пустой или содержит недопустимые символы.'
    }
}

function Invoke-ModuleAccelerator {
    while ($true) {
        $items = @(
            [pscustomobject]@{ Key = '1'; Title = 'Задать акселератор для выбранных версий'; Desc = 'Записывает RSACCELERATOR<год> в переменные пользователя' },
            [pscustomobject]@{ Key = '2'; Title = 'Задать акселератор для всех версий'; Desc = "Revit $($Script:AcceleratorVersions[0])-$($Script:AcceleratorVersions[-1])" },
            [pscustomobject]@{ Key = '3'; Title = 'Отключить акселератор для выбранных версий'; Desc = 'Удаляет переменные окружения' },
            [pscustomobject]@{ Key = '4'; Title = 'Отключить акселератор для всех версий'; Desc = 'Полный сброс' },
            [pscustomobject]@{ Key = '5'; Title = 'Показать текущие значения'; Desc = 'Таблица по всем годам' }
        )

        $choice = Show-Menu -Items $items -Title 'менеджер Revit Server Accelerator' -BackText 'Назад'
        if ($choice -eq '0') { return }

        Write-Banner
        Write-LogHeader "ACCELERATOR $choice"

        switch ($choice) {
            '1' {
                Write-Prompt 'акселератор для выбранных версий'
                $versions = Select-RevitVersionForAccelerator
                if ($versions.Count -eq 0) { Write-Blank; Write-Info 'Ничего не выбрано.'; Wait-Menu; break }

                $address = Read-AcceleratorAddress
                Write-Blank
                foreach ($version in $versions) { Write-Add "RSACCELERATOR$version = $address" }

                Write-Blank
                if (Test-DryRun "запись $($versions.Count) переменных окружения") { Wait-Menu; break }
                if (-not (Confirm-Action -Question "Записать адрес для версий: $($versions -join ', ')?")) { Write-Info 'Отменено.'; Wait-Menu; break }

                foreach ($version in $versions) { Set-AcceleratorValue -Version $version -Address $address }
                Update-EnvironmentBroadcast | Out-Null

                Write-Blank
                Write-Ok "Готово. Перезапустите Revit, чтобы настройка применилась."
                Wait-Menu
            }

            '2' {
                Write-Prompt 'акселератор для всех версий'
                $address = Read-AcceleratorAddress
                Write-Blank
                foreach ($version in $Script:AcceleratorVersions) { Write-Add "RSACCELERATOR$version = $address" }

                Write-Blank
                if (Test-DryRun 'запись переменных для всех версий') { Wait-Menu; break }
                if (-not (Confirm-Action -Question "Задать '$address' для всех версий?")) { Write-Info 'Отменено.'; Wait-Menu; break }

                foreach ($version in $Script:AcceleratorVersions) { Set-AcceleratorValue -Version $version -Address $address }
                Update-EnvironmentBroadcast | Out-Null

                Write-Blank
                Write-Ok 'Готово. Перезапустите Revit.'
                Wait-Menu
            }

            '3' {
                Write-Prompt 'отключение акселератора'
                $versions = Select-RevitVersionForAccelerator
                if ($versions.Count -eq 0) { Write-Blank; Write-Info 'Ничего не выбрано.'; Wait-Menu; break }

                Write-Blank
                foreach ($version in $versions) { Write-Del "RSACCELERATOR$version" }

                Write-Blank
                if (Test-DryRun "удаление $($versions.Count) переменных") { Wait-Menu; break }
                if (-not (Confirm-Action -Question "Удалить переменные для версий: $($versions -join ', ')?")) { Write-Info 'Отменено.'; Wait-Menu; break }

                foreach ($version in $versions) { Remove-AcceleratorValue -Version $version }
                Update-EnvironmentBroadcast | Out-Null

                Write-Blank
                Write-Ok 'Готово.'
                Wait-Menu
            }

            '4' {
                Write-Prompt 'отключение акселератора для всех версий'
                Write-Blank
                foreach ($version in $Script:AcceleratorVersions) { Write-Del "RSACCELERATOR$version" }

                Write-Blank
                if (Test-DryRun 'удаление всех переменных RSACCELERATOR') { Wait-Menu; break }
                if (-not (Confirm-Action -Question 'Удалить RSACCELERATOR для всех версий?' -Danger)) { Write-Info 'Отменено.'; Wait-Menu; break }

                foreach ($version in $Script:AcceleratorVersions) { Remove-AcceleratorValue -Version $version }
                Update-EnvironmentBroadcast | Out-Null

                Write-Blank
                Write-Ok 'Готово.'
                Wait-Menu
            }

            '5' {
                Write-Prompt 'текущие значения'
                Show-AcceleratorTable
                Wait-Menu
            }
        }
    }
}

# ============================================================================
#  МОДУЛЬ 4: Очистка следов Revit
#  (Clean-Revit)
# ============================================================================

function Get-UserProfileFolder {
    return @(Get-ChildItem -LiteralPath 'C:\Users' -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -notin @('All Users', 'Default', 'Default User', 'Public') })
}

function Resolve-RevitUserPath {
    param([string]$Version)
    $paths = New-Object System.Collections.Generic.List[string]

    @(
        "C:\Program Files\Autodesk\Revit $Version",
        "C:\Program Files\Autodesk\Autodesk Revit $Version",
        "C:\ProgramData\Autodesk\RVT $Version",
        "C:\ProgramData\Autodesk\Revit\Addins\$Version",
        "C:\ProgramData\Autodesk\Revit\Extensions\$Version",
        "C:\ProgramData\Autodesk\Revit\Steel Connections $Version",
        "C:\ProgramData\Microsoft\Windows\Start Menu\Programs\Autodesk\Revit $Version",
        "C:\ProgramData\Microsoft\Windows\Start Menu\Programs\Autodesk\Autodesk Revit $Version"
    ) | ForEach-Object { $paths.Add($_) }

    foreach ($folder in (Get-UserProfileFolder)) {
        $userRoot = $folder.FullName
        @(
            "$userRoot\AppData\Roaming\Autodesk\Revit\Autodesk Revit $Version",
            "$userRoot\AppData\Roaming\Autodesk\Revit\Addins\$Version",
            "$userRoot\AppData\Roaming\Autodesk\Revit\Extensions\$Version",
            "$userRoot\AppData\Local\Autodesk\Revit\Autodesk Revit $Version",
            "$userRoot\AppData\Local\Autodesk\Revit\Addins\$Version",
            "$userRoot\AppData\Local\Autodesk\Revit\Journals\$Version",
            "$userRoot\AppData\Local\Autodesk\Web Services\Revit $Version"
        ) | ForEach-Object { $paths.Add($_) }
    }

    return @($paths | Sort-Object -Unique)
}

function Resolve-RevitRegistryPath {
    param([string]$Version)
    $paths = New-Object System.Collections.Generic.List[string]

    @(
        "HKLM:\SOFTWARE\Autodesk\Revit\$Version",
        "HKLM:\SOFTWARE\Autodesk\Revit\Autodesk Revit $Version",
        "HKLM:\SOFTWARE\Autodesk\RVT $Version",
        "HKLM:\SOFTWARE\WOW6432Node\Autodesk\Revit\$Version",
        "HKLM:\SOFTWARE\WOW6432Node\Autodesk\Revit\Autodesk Revit $Version",
        "HKCU:\SOFTWARE\Autodesk\Revit\$Version",
        "HKCU:\SOFTWARE\Autodesk\Revit\Autodesk Revit $Version"
    ) | ForEach-Object { if (Test-Path -LiteralPath $_) { $paths.Add($_) } }

    Get-UninstallEntry |
        Where-Object { "$($_.DisplayName) $($_.DisplayVersion)" -match [regex]::Escape($Version) } |
        ForEach-Object { $paths.Add($_.RegistryPath) }

    return @($paths | Sort-Object -Unique)
}

function Test-RevitVersionText {
    param([string]$Text, [string]$Version)
    if ([string]::IsNullOrWhiteSpace($Text)) { return $false }
    return ($Text -match 'Revit' -and $Text -match [regex]::Escape($Version))
}

function Add-UniqueExistingPath {
    param($List, [string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return }
    if ((Test-Path -LiteralPath $Path) -and (-not $List.Contains($Path))) { [void]$List.Add($Path) }
}

function Test-FolderHasRevitMarker {
    param([string]$Path, [string]$Version)
    if (-not (Test-Path -LiteralPath $Path)) { return $false }
    if (Test-RevitVersionText $Path $Version) { return $true }

    $markers = Get-ChildItem -LiteralPath $Path -File -Recurse -ErrorAction SilentlyContinue |
        Where-Object { $_.Length -lt 5MB -and $_.Extension -match '\.(xml|json|txt|ini|log|html|htm|js|config)$' } |
        Select-Object -First 30

    foreach ($file in $markers) {
        try {
            if (-not (Select-String -LiteralPath $file.FullName -Pattern 'Revit' -SimpleMatch -Quiet -ErrorAction SilentlyContinue)) { continue }
            if (Select-String -LiteralPath $file.FullName -Pattern $Version -SimpleMatch -Quiet -ErrorAction SilentlyContinue) { return $true }
        }
        catch { }
    }
    return $false
}

function Resolve-RevitDeepFilePath {
    param([string]$Version)
    $paths = New-Object System.Collections.Generic.List[string]

    @(
        "C:\Autodesk\Revit $Version",
        "C:\Autodesk\Autodesk Revit $Version",
        "C:\Autodesk\RVT $Version",
        "C:\ProgramData\Autodesk\ODIS\logs\Revit $Version",
        "C:\ProgramData\Autodesk\ODIS\downloads\Revit $Version",
        "C:\ProgramData\Autodesk\ODIS\cache\Revit $Version",
        "C:\ProgramData\Autodesk\Uninstallers\Autodesk Revit $Version",
        "C:\ProgramData\Autodesk\Uninstallers\Revit $Version"
    ) | ForEach-Object { Add-UniqueExistingPath $paths $_ }

    $scanRoots = @(
        'C:\Autodesk',
        'C:\ProgramData\Autodesk\ODIS\metadata',
        'C:\ProgramData\Autodesk\ODIS\manifest',
        'C:\ProgramData\Autodesk\ODIS\downloads',
        'C:\ProgramData\Autodesk\UPI2',
        'C:\ProgramData\Autodesk\Uninstallers'
    )

    foreach ($root in $scanRoots) {
        if (-not (Test-Path -LiteralPath $root)) { continue }
        Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue | ForEach-Object {
            if (Test-FolderHasRevitMarker $_.FullName $Version) { Add-UniqueExistingPath $paths $_.FullName }
        }
    }

    foreach ($folder in (Get-UserProfileFolder)) {
        $userRoot = $folder.FullName
        @(
            "$userRoot\AppData\Local\Temp\Autodesk Revit $Version",
            "$userRoot\AppData\Local\Temp\Revit $Version",
            "$userRoot\AppData\Local\Autodesk\ODIS\Revit $Version",
            "$userRoot\AppData\Local\Autodesk\Webdeploy\production\Revit $Version"
        ) | ForEach-Object { Add-UniqueExistingPath $paths $_ }
    }

    return @($paths | Sort-Object -Unique)
}

function Get-RegistryPropertyText {
    param($Props)
    $parts = New-Object System.Collections.Generic.List[string]
    foreach ($property in $Props.PSObject.Properties) {
        if ($property.Name -match '^PS') { continue }
        if ($null -ne $property.Value) { [void]$parts.Add([string]$property.Value) }
    }
    return ($parts -join ' ')
}

function Resolve-RevitDeepRegistryPath {
    param([string]$Version)
    $paths = New-Object System.Collections.Generic.List[string]

    $roots = @(
        'HKLM:\SOFTWARE\Autodesk\UPI2',
        'HKLM:\SOFTWARE\WOW6432Node\Autodesk\UPI2',
        'HKLM:\SOFTWARE\Autodesk\ODIS',
        'HKLM:\SOFTWARE\WOW6432Node\Autodesk\ODIS',
        'HKLM:\SOFTWARE\Autodesk\MC3',
        'HKLM:\SOFTWARE\WOW6432Node\Autodesk\MC3'
    )

    foreach ($root in $roots) {
        if (-not (Test-Path -LiteralPath $root)) { continue }
        Get-ChildItem -LiteralPath $root -Recurse -ErrorAction SilentlyContinue | ForEach-Object {
            $props = Get-ItemProperty -LiteralPath $_.PSPath -ErrorAction SilentlyContinue
            $text = "$($_.Name) $(Get-RegistryPropertyText $props)"
            if (Test-RevitVersionText $text $Version) { Add-UniqueExistingPath $paths $_.PSPath }
        }
    }

    $installerProducts = New-Object System.Collections.Generic.List[string]
    [void]$installerProducts.Add('HKLM:\SOFTWARE\Classes\Installer\Products')

    $userDataRoot = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Installer\UserData'
    if (Test-Path -LiteralPath $userDataRoot) {
        Get-ChildItem -LiteralPath $userDataRoot -ErrorAction SilentlyContinue | ForEach-Object {
            $productsPath = Join-Path $_.PSPath 'Products'
            if (Test-Path -LiteralPath $productsPath) { [void]$installerProducts.Add($productsPath) }
        }
    }

    foreach ($root in $installerProducts) {
        if (-not (Test-Path -LiteralPath $root)) { continue }
        Get-ChildItem -LiteralPath $root -ErrorAction SilentlyContinue | ForEach-Object {
            $productKey = $_
            $props = Get-ItemProperty -LiteralPath $productKey.PSPath -ErrorAction SilentlyContinue
            $text = "$($productKey.Name) $(Get-RegistryPropertyText $props)"

            $installPropsPath = Join-Path $productKey.PSPath 'InstallProperties'
            if (Test-Path -LiteralPath $installPropsPath) {
                $installProps = Get-ItemProperty -LiteralPath $installPropsPath -ErrorAction SilentlyContinue
                $text = "$text $(Get-RegistryPropertyText $installProps)"
            }

            if (Test-RevitVersionText $text $Version) { Add-UniqueExistingPath $paths $productKey.PSPath }
        }
    }

    return @($paths | Sort-Object -Unique)
}

function Get-RevitCleanupPlan {
    param([string]$Version)
    $items = New-Object System.Collections.Generic.List[object]

    foreach ($path in @(Resolve-RevitUserPath $Version | Where-Object { Test-Path -LiteralPath $_ })) {
        $items.Add([pscustomobject]@{ Type = 'Файлы'; Path = $path })
    }
    foreach ($path in @(Resolve-RevitDeepFilePath $Version)) {
        $items.Add([pscustomobject]@{ Type = 'Кэш/остатки'; Path = $path })
    }
    foreach ($path in @(Resolve-RevitRegistryPath $Version)) {
        $items.Add([pscustomobject]@{ Type = 'Реестр'; Path = $path })
    }
    foreach ($path in @(Resolve-RevitDeepRegistryPath $Version)) {
        $items.Add([pscustomobject]@{ Type = 'Реестр (глубоко)'; Path = $path })
    }

    return @($items | Sort-Object Type, Path -Unique)
}

function Remove-CleanupItem {
    param($Item)
    try {
        if (Test-Path -LiteralPath $Item.Path) {
            Remove-Item -LiteralPath $Item.Path -Recurse -Force -ErrorAction Stop
        }
        if (Test-Path -LiteralPath $Item.Path) {
            return [pscustomobject]@{ Ok = $false; Message = "осталось после удаления: $($Item.Path)" }
        }
        return [pscustomobject]@{ Ok = $true; Message = $Item.Path }
    }
    catch {
        return [pscustomobject]@{ Ok = $false; Message = "$($Item.Path) $($Script:G.Dot) $($_.Exception.Message)" }
    }
}

function Get-AdskLicensingVersionText {
    $candidates = @(
        'C:\Program Files (x86)\Common Files\Autodesk Shared\AdskLicensing\Current\AdskLicensingService\AdskLicensingService.exe',
        'C:\Program Files (x86)\Common Files\Autodesk Shared\AdskLicensing\AdskLicensingService\AdskLicensingService.exe'
    )
    foreach ($path in $candidates) {
        if (Test-Path -LiteralPath $path) {
            $info = Get-Item -LiteralPath $path -ErrorAction SilentlyContinue
            if ($info -and $info.VersionInfo.FileVersion) { return $info.VersionInfo.FileVersion }
        }
    }
    return 'не найдено'
}

function Get-AdskLicensingInstaller {
    return @(Get-ChildItem -LiteralPath $Script:Root -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match '^AdskLicensing-installer .*\.exe$' } |
        Sort-Object {
            if ($_.BaseName -match '(\d+\.\d+\.\d+\.\d+)') { [version]$matches[1] } else { [version]'0.0.0.0' }
        } -Descending)
}

function Invoke-AdskLicensingUpdate {
    Write-Banner
    Write-Prompt 'обновление Autodesk Licensing Service'
    Write-LogHeader 'ADSK LICENSING'

    if (-not (Assert-Admin -Reason 'Переустановка службы лицензирования требует прав администратора.')) { Wait-Menu; return }

    $installers = @(Get-AdskLicensingInstaller)
    Write-Blank
    Write-Kv 'Текущая версия' (Get-AdskLicensingVersionText)

    if ($installers.Count -eq 0) {
        Write-Blank
        Write-Fail 'Установщик не найден.'
        Write-Info "Положите файл вида 'AdskLicensing-installer 11.x.x.x.exe' рядом со скриптом:"
        Write-Info $Script:Root
        Wait-Menu
        return
    }

    $installer = $installers[0]
    Write-Kv 'Установщик' $installer.Name

    Write-Blank
    if (Test-DryRun 'остановка службы, удаление старой версии, установка новой') { Wait-Menu; return }
    if (-not (Confirm-Action -Question 'Переустановить AdskLicensing?' -Danger)) { Write-Info 'Отменено.'; Wait-Menu; return }

    Write-Blank
    Invoke-Step -Text 'stop AdskLicensingService' -Action {
        Get-Service -Name 'AdskLicensingService' -ErrorAction SilentlyContinue | Stop-Service -Force -ErrorAction SilentlyContinue
        Get-Process -Name 'AdskLicensingService', 'AdskLicensingAgent', 'AdskLicensingInstHelper' -ErrorAction SilentlyContinue |
            Stop-Process -Force -ErrorAction SilentlyContinue
    } | Out-Null

    $uninstallers = @(
        'C:\Program Files (x86)\Common Files\Autodesk Shared\AdskLicensing\uninstall.exe',
        'C:\Program Files (x86)\Common Files\Autodesk Shared\AdskLicensing\Current\AdskLicensingService\uninstall.exe'
    ) | Where-Object { Test-Path -LiteralPath $_ }

    foreach ($uninstaller in $uninstallers) {
        Invoke-Step -Text "uninstall $(Split-Path $uninstaller -Parent | Split-Path -Leaf)" -Action {
            $process = Start-Process -FilePath $uninstaller -ArgumentList '--mode unattended' -Wait -PassThru -ErrorAction Stop
            Write-Log "     exit code $($process.ExitCode)"
        } | Out-Null
    }

    Invoke-Step -Text "install $($installer.Name)" -Action {
        $process = Start-Process -FilePath $installer.FullName -ArgumentList '--mode unattended' -Wait -PassThru -ErrorAction Stop
        Write-Log "     exit code $($process.ExitCode)"
    } | Out-Null

    Invoke-Step -Text 'start AdskLicensingService' -Action {
        Get-Service -Name 'AdskLicensingService' -ErrorAction SilentlyContinue | Start-Service -ErrorAction SilentlyContinue
    } | Out-Null

    Write-Blank
    Write-Ok "Новая версия: $(Get-AdskLicensingVersionText)"
    Wait-Menu
}

function Invoke-RevitCleanup {
    Write-Banner
    Write-Prompt 'очистка следов Revit'
    Write-LogHeader 'CLEAN REVIT'

    if (-not (Assert-Admin -Reason 'Удаление файлов в Program Files и веток реестра HKLM требует прав администратора.')) { Wait-Menu; return }

    Write-Blank
    Write-Tool 'reading' 'реестр + Program Files + профили пользователей'
    $versions = @(Get-DetectedRevitVersion)

    $version = $null
    if ($versions.Count -gt 0) {
        $options = @()
        foreach ($v in $versions) { $options += "Revit $v" }
        $options += 'Ввести версию вручную'

        $selected = Read-Selection -Options $options -Title 'Версия для очистки (выберите одну)'
        if ($selected.Count -eq 0) { Write-Blank; Write-Info 'Отменено.'; Wait-Menu; return }

        $idx = $selected[0]
        if ($idx -lt $versions.Count) { $version = $versions[$idx] }
    }

    if (-not $version) {
        $version = Read-Text -Label 'Версия Revit' -Hint 'Четыре цифры, например 2022'
    }

    if ($version -notmatch '^20\d{2}$') {
        Write-Blank
        Write-Fail 'Неверный формат версии.'
        Wait-Menu
        return
    }

    Write-Banner
    Write-Prompt "поиск следов Revit $version"
    Write-Blank

    $plan = Invoke-Step -Text "scan filesystem + registry (Revit $version)" -Action { Get-RevitCleanupPlan $version }
    $plan = @($plan)

    Write-Blank
    if ($plan.Count -eq 0) {
        Write-Ok "Следы Revit $version не найдены."
        Wait-Menu
        return
    }

    Write-Bullet "Найдено объектов: $($plan.Count)"
    Write-Blank

    $groups = $plan | Group-Object Type
    foreach ($group in $groups) {
        Write-Host ("  " + $Script:C.Cyan + $group.Name + $Script:C.Reset + $Script:C.Faint + "  ($($group.Count))" + $Script:C.Reset)
        foreach ($item in $group.Group) {
            Write-Host ("    " + $Script:C.Faint + $item.Path + $Script:C.Reset)
            Write-Log "     $($item.Type) | $($item.Path)"
        }
        Write-Blank
    }

    if (Test-DryRun "удаление $($plan.Count) объектов (файлы и ветки реестра)") { Wait-Menu; return }

    Write-Warn 'Операция необратима. Рекомендуется закрыть Revit и сделать точку восстановления.'
    if (-not (Confirm-Action -Question "Удалить все $($plan.Count) объектов для Revit $version?" -Danger)) {
        Write-Info 'Отменено.'
        Wait-Menu
        return
    }

    Write-Blank
    $removed = 0
    $errors = 0
    $total = $plan.Count
    $i = 0

    foreach ($item in $plan) {
        $i++
        Write-Bar -Current $i -Total $total -Text "удаление $i / $total"
        $result = Remove-CleanupItem -Item $item
        if ($result.Ok) { $removed++; Write-Log "  DELETED $($item.Type) | $($item.Path)" }
        else { $errors++; Write-Log "  ERROR $($result.Message)" }
    }

    Write-Blank
    Write-Bullet "Удалено: $removed   Ошибок: $errors"
    if ($errors -gt 0) {
        Write-Info "Подробности в логе: $($Script:Ctx.LogPath)"
        Write-Info 'Часть объектов может быть занята процессами Revit или защищена системой.'
    }
    Write-Blank
    Write-Warn 'Перед новой установкой Revit перезагрузите Windows.'

    Wait-Menu
}

function Invoke-ModuleClean {
    while ($true) {
        $items = @(
            [pscustomobject]@{ Key = '1'; Title = 'Поиск и удаление следов Revit'; Desc = 'Файлы, кэш ODIS/UPI2, ветки реестра, записи установщика' },
            [pscustomobject]@{ Key = '2'; Title = 'Обновить Autodesk Licensing Service'; Desc = 'Требуется AdskLicensing-installer *.exe рядом со скриптом' }
        )

        $choice = Show-Menu -Items $items -Title 'очистка Revit' -BackText 'Назад'
        switch ($choice) {
            '0' { return }
            '1' { Invoke-RevitCleanup }
            '2' { Invoke-AdskLicensingUpdate }
        }
    }
}

# ============================================================================
#  МОДУЛЬ 5: Backup-папки и журналы
#  (find_revit_backups_and_journals)
# ============================================================================

function Find-RevitBackupFolder {
    param([string]$SearchRoot)

    return @(Get-ChildItem -LiteralPath $SearchRoot -Directory -Recurse -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -like '*_backup' -and $_.Name -ne '_backup' })
}

function Get-MatchingRvtFile {
    param($BackupFolder)

    $modelName = $BackupFolder.Name -replace '_backup$', ''
    if ([string]::IsNullOrWhiteSpace($modelName)) { return $null }

    return (Get-ChildItem -LiteralPath $BackupFolder.Parent.FullName -Filter '*.rvt' -File -ErrorAction SilentlyContinue |
        Where-Object {
            $_.BaseName -eq $modelName -or
            $_.BaseName -like "$modelName*" -or
            $modelName -like "$($_.BaseName)*"
        } | Select-Object -First 1)
}

function Find-RevitJournal {
    param([int]$KeepDays = 7, [int]$KeepLast = 5)

    $root = Join-Path $env:LOCALAPPDATA 'Autodesk\Revit'
    if (-not (Test-Path -LiteralPath $root)) { return @() }

    $all = @(Get-ChildItem -LiteralPath $root -Recurse -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match '^journal.*\.(txt|log)$' })

    if ($all.Count -eq 0) { return @() }

    $cutoff = (Get-Date).AddDays(-$KeepDays)
    $keep = @($all | Sort-Object LastWriteTime -Descending | Select-Object -First $KeepLast)
    $keepPaths = @($keep | ForEach-Object { $_.FullName })

    return @($all | Where-Object { $_.LastWriteTime -lt $cutoff -and ($keepPaths -notcontains $_.FullName) })
}

function Format-Size {
    param([long]$Bytes)
    if ($Bytes -gt 1GB) { return ("{0:N2} ГБ" -f ($Bytes / 1GB)) }
    if ($Bytes -gt 1MB) { return ("{0:N1} МБ" -f ($Bytes / 1MB)) }
    if ($Bytes -gt 1KB) { return ("{0:N0} КБ" -f ($Bytes / 1KB)) }
    return "$Bytes Б"
}

function Get-FolderSize {
    param([string]$Path)
    try {
        $sum = (Get-ChildItem -LiteralPath $Path -Recurse -File -ErrorAction SilentlyContinue |
            Measure-Object -Property Length -Sum).Sum
        if ($null -eq $sum) { return 0 }
        return [long]$sum
    }
    catch { return 0 }
}

function Invoke-ModuleBackups {
    Write-Banner
    Write-Prompt 'backup-папки и журналы Revit'
    Write-LogHeader 'BACKUPS AND JOURNALS'

    $documents = [Environment]::GetFolderPath('MyDocuments')

    Write-Blank
    Write-Kv 'Область поиска backup' $documents
    Write-Kv 'Журналы' (Join-Path $env:LOCALAPPDATA 'Autodesk\Revit')
    Write-Kv 'Политика журналов' 'старше 7 дней, последние 5 всегда сохраняются'

    $customRoot = Read-Text -Label 'Другая папка для поиска backup (Enter = по умолчанию)'
    if (-not [string]::IsNullOrWhiteSpace($customRoot)) {
        if (Test-Path -LiteralPath $customRoot) { $documents = $customRoot }
        else { Write-Fail 'Путь не найден, используется папка по умолчанию.' }
    }

    Write-Blank
    $backups = Invoke-Step -Text "scan $documents (*_backup)" -Action { Find-RevitBackupFolder -SearchRoot $documents }
    $backups = @($backups)

    $journals = Invoke-Step -Text 'scan journals' -Action { Find-RevitJournal -KeepDays 7 -KeepLast 5 }
    $journals = @($journals)

    # Классификация backup-папок
    $safeBackups = @()
    $orphanBackups = @()

    foreach ($folder in $backups) {
        $rvt = Get-MatchingRvtFile -BackupFolder $folder
        $entry = [pscustomobject]@{
            Path    = $folder.FullName
            Related = if ($rvt) { $rvt.FullName } else { '' }
            Size    = Get-FolderSize -Path $folder.FullName
        }
        if ($rvt) { $safeBackups += $entry } else { $orphanBackups += $entry }
    }

    $backupSize = ($safeBackups | Measure-Object -Property Size -Sum).Sum
    if ($null -eq $backupSize) { $backupSize = 0 }
    $journalSize = ($journals | Measure-Object -Property Length -Sum).Sum
    if ($null -eq $journalSize) { $journalSize = 0 }

    Write-Blank
    Write-Bullet 'Результат поиска'
    Write-Blank
    Write-Kv 'Backup-папок найдено' ([string]$backups.Count)
    Write-Kv 'Из них с живым .rvt' ("$($safeBackups.Count)   $(Format-Size $backupSize)") $Script:C.Green
    Write-Kv 'Без парного .rvt' ("$($orphanBackups.Count)   (пропускаются)") $Script:C.Yellow
    Write-Kv 'Журналов к удалению' ("$($journals.Count)   $(Format-Size $journalSize)")

    if ($safeBackups.Count -gt 0) {
        Write-Blank
        Write-Host ("  " + $Script:C.Cyan + 'Backup-папки к удалению' + $Script:C.Reset)
        foreach ($entry in ($safeBackups | Select-Object -First 40)) {
            Write-Host ("    " + $Script:C.Faint + "$($entry.Path)   [$(Format-Size $entry.Size)]" + $Script:C.Reset)
            Write-Log "     BACKUP $($entry.Path) -> $($entry.Related)"
        }
        if ($safeBackups.Count -gt 40) { Write-Info "... и ещё $($safeBackups.Count - 40)" }
    }

    if ($orphanBackups.Count -gt 0) {
        Write-Blank
        Write-Host ("  " + $Script:C.Yellow + 'Пропущено: не найден парный .rvt' + $Script:C.Reset)
        foreach ($entry in ($orphanBackups | Select-Object -First 20)) {
            Write-Host ("    " + $Script:C.Faint + $entry.Path + $Script:C.Reset)
        }
        if ($orphanBackups.Count -gt 20) { Write-Info "... и ещё $($orphanBackups.Count - 20)" }
    }

    # Отчёт CSV
    $report = @()
    foreach ($entry in $safeBackups)   { $report += [pscustomobject]@{ Type = 'Backup'; Path = $entry.Path; Related = $entry.Related; Size = $entry.Size; Status = 'Planned' } }
    foreach ($entry in $orphanBackups) { $report += [pscustomobject]@{ Type = 'Backup'; Path = $entry.Path; Related = ''; Size = $entry.Size; Status = 'Skipped (no RVT)' } }
    foreach ($journal in $journals)    { $report += [pscustomobject]@{ Type = 'Journal'; Path = $journal.FullName; Related = ''; Size = $journal.Length; Status = 'Planned' } }

    $reportPath = Join-Path $documents ("Revit_Backup_Report_{0}.csv" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))

    if ($safeBackups.Count -eq 0 -and $journals.Count -eq 0) {
        Write-Blank
        Write-Ok 'Удалять нечего.'
        Wait-Menu
        return
    }

    Write-Blank
    $freed = Format-Size ($backupSize + $journalSize)
    if (Test-DryRun "удаление $($safeBackups.Count) backup-папок и $($journals.Count) журналов, освободится $freed") {
        try {
            $report | Export-Csv -LiteralPath $reportPath -NoTypeInformation -Encoding UTF8
            Write-Ok "Отчёт: $reportPath"
        }
        catch { Write-Fail "не удалось сохранить отчёт: $($_.Exception.Message)" }
        Wait-Menu
        return
    }

    if (-not (Confirm-Action -Question "Удалить $($safeBackups.Count) backup-папок и $($journals.Count) журналов (освободится $freed)?" -Danger)) {
        Write-Info 'Отменено. Сохраняю только отчёт.'
        try {
            $report | Export-Csv -LiteralPath $reportPath -NoTypeInformation -Encoding UTF8
            Write-Ok "Отчёт: $reportPath"
        }
        catch { Write-Fail "не удалось сохранить отчёт: $($_.Exception.Message)" }
        Wait-Menu
        return
    }

    Write-Blank
    $deletedBackups = 0
    $failedBackups = 0
    $total = $safeBackups.Count + $journals.Count
    $i = 0

    foreach ($entry in $safeBackups) {
        $i++
        Write-Bar -Current $i -Total $total -Text 'backup-папки'
        try {
            Remove-Item -LiteralPath $entry.Path -Recurse -Force -ErrorAction Stop
            $deletedBackups++
            ($report | Where-Object { $_.Path -eq $entry.Path }) | ForEach-Object { $_.Status = 'Deleted' }
            Write-Log "  DELETED BACKUP $($entry.Path)"
        }
        catch {
            $failedBackups++
            ($report | Where-Object { $_.Path -eq $entry.Path }) | ForEach-Object { $_.Status = 'Delete Failed' }
            Write-Log "  ERROR BACKUP $($entry.Path): $($_.Exception.Message)"
        }
    }

    $deletedJournals = 0
    $failedJournals = 0

    foreach ($journal in $journals) {
        $i++
        Write-Bar -Current $i -Total $total -Text 'журналы'
        try {
            Remove-Item -LiteralPath $journal.FullName -Force -ErrorAction Stop
            $deletedJournals++
            ($report | Where-Object { $_.Path -eq $journal.FullName }) | ForEach-Object { $_.Status = 'Deleted' }
            Write-Log "  DELETED JOURNAL $($journal.FullName)"
        }
        catch {
            $failedJournals++
            ($report | Where-Object { $_.Path -eq $journal.FullName }) | ForEach-Object { $_.Status = 'Delete Failed' }
            Write-Log "  ERROR JOURNAL $($journal.FullName): $($_.Exception.Message)"
        }
    }

    Write-Blank
    Write-Bullet 'Итог'
    Write-Blank
    Write-Kv 'Удалено backup-папок' ("$deletedBackups из $($safeBackups.Count)") $Script:C.Green
    Write-Kv 'Удалено журналов' ("$deletedJournals из $($journals.Count)") $Script:C.Green
    if ($failedBackups -gt 0 -or $failedJournals -gt 0) {
        Write-Kv 'Ошибок' ([string]($failedBackups + $failedJournals)) $Script:C.Red
    }
    Write-Kv 'Освобождено' $freed

    try {
        $report | Export-Csv -LiteralPath $reportPath -NoTypeInformation -Encoding UTF8
        Write-Blank
        Write-Ok "Отчёт: $reportPath"
    }
    catch { Write-Fail "не удалось сохранить отчёт: $($_.Exception.Message)" }

    Wait-Menu
}

# ============================================================================
#  БЛОК 5. Настройки сессии и главное меню
# ============================================================================

function Invoke-ModuleAutodesk {
    # Local scope keeps imported helper names out of the toolkit's shared UI.
    $ScriptRoot = $Script:Root
    $StateDir = Join-Path $env:ProgramData 'AutodeskDefenderExclusions'
    $StateFile = Join-Path $StateDir 'managed.json'
    $LegacyMarker = Join-Path $ScriptRoot 'Autodesk_Defender_Exclusions.managed.json'
    $ExtraFile = Join-Path $ScriptRoot 'ExtraPaths.txt'

    function Write-AutodeskLog {
        param([string]$Message, [string]$Level = 'INFO')
        Write-Log "[Autodesk][$Level] $Message"
        switch ($Level) {
            'OK' { Write-Ok $Message }
            'WARN' { Write-Warn $Message }
            'ERROR' { Write-Fail $Message }
            default { Write-Info $Message }
        }
    }

$PF   = if ($env:ProgramW6432) { $env:ProgramW6432 } else { $env:ProgramFiles }
$PF86 = ${env:ProgramFiles(x86)}
$PD   = $env:ProgramData

$UsersRoot = "$env:SystemDrive\Users"
try {
    $profilesDirectory = (Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList' -Name ProfilesDirectory -ErrorAction Stop).ProfilesDirectory
    if ($profilesDirectory) { $UsersRoot = [Environment]::ExpandEnvironmentVariables($profilesDirectory) }
} catch {}

$NamePattern = 'Autodesk|Revit|pyRevit'

# ------------------------------------------------------------------
# Процессы Autodesk (исключение по имени действует для любого пути)
# ------------------------------------------------------------------
$ProcessList = @(
    # Revit
    'Revit.exe', 'RevitWorker.exe', 'RevitAccelerator.exe',
    # AutoCAD и вертикали (Civil 3D, Architecture и др. работают через acad.exe)
    'acad.exe', 'accoreconsole.exe', 'AcWebBrowser.exe', 'AdAppMgrSvc.exe',
    # 3ds Max
    '3dsmax.exe', '3dsmaxbatch.exe', '3dsmaxcmd.exe',
    # Navisworks
    'Roamer.exe', 'FiletoolsTaskRunner.exe',
    # Inventor, Maya
    'Inventor.exe', 'maya.exe',
    # Лицензирование, вход, обновления
    'AdskLicensingService.exe', 'AdskLicensingAgent.exe',
    'AdskAccessCore.exe', 'AdskAccessService.exe', 'AdskAccessServiceHost.exe', 'AdskAccessUIHost.exe',
    'AdskIdentityManager.exe', 'AdskIdentityManagerUI.exe', 'AdSSO.exe',
    'AdskUpdateCheck.exe', 'AdskInstaller.exe', 'AdskNetworkService.exe',
    'AutodeskAccess.exe', 'AutodeskDesktopApp.exe',
    'GenuineService.exe', 'ADPClientService.exe',
    # Desktop Connector
    'DesktopConnector.Applications.Tray.exe',
    # Сетевой сервер лицензий (FlexNet)
    'adskflex.exe', 'lmgrd.exe', 'FNPLicensingService.exe'
)

# ------------------------------------------------------------------
# Пути
# ------------------------------------------------------------------
function Get-NormalizedPath {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return $null }
    $p = [Environment]::ExpandEnvironmentVariables($Path.Trim().Trim('"'))
    # Только абсолютные локальные пути или UNC
    if ($p -notmatch '^([A-Za-z]:\\|\\\\[^\\]+\\)') { return $null }
    try { $p = [System.IO.Path]::GetFullPath($p) } catch { return $null }
    return $p.TrimEnd('\')
}

# Каталоги, которые нельзя исключать целиком (защита от кривых записей в реестре)
$Forbidden = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
@($PF, $PF86, $PD, $env:SystemRoot, $UsersRoot,
  "$PF\Common Files", "$PF86\Common Files",
  "$env:SystemDrive\", "$UsersRoot\Public") |
    ForEach-Object { $n = Get-NormalizedPath $_; if ($n) { [void]$Forbidden.Add($n) } }

function Test-SafeExclusionPath {
    param([string]$Path)
    if (-not $Path) { return $false }
    if ($Path -match '^[A-Za-z]:$') { return $false }            # корень диска
    if ($Forbidden.Contains($Path)) { return $false }
    $parent = Split-Path -Parent $Path
    if ($parent -and ($parent.TrimEnd('\') -ieq $UsersRoot.TrimEnd('\'))) { return $false }  # корень профиля
    return $true
}

function Get-UserProfilePaths {
    $list = @()
    try {
        $list = @(Get-CimInstance -ClassName Win32_UserProfile -ErrorAction Stop |
            Where-Object { -not $_.Special -and $_.LocalPath -and (Test-Path -LiteralPath $_.LocalPath) } |
            ForEach-Object { $_.LocalPath })
    } catch {
        $list = @(Get-ChildItem -LiteralPath $UsersRoot -Directory -Force -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -notin @('Public', 'Default', 'Default User', 'All Users') } |
            ForEach-Object { $_.FullName })
    }
    return @($list | Sort-Object -Unique)
}

function Get-ExclusionTargets {
    $found = New-Object 'System.Collections.Generic.Dictionary[string,string]' ([StringComparer]::OrdinalIgnoreCase)

    $add = {
        param([string]$Path, [string]$Source, [bool]$AllowMissing)
        $n = Get-NormalizedPath $Path
        if (-not $n) { return }
        if (-not (Test-SafeExclusionPath $n)) {
            Write-AutodeskLog "Пропущен слишком широкий путь ($Source): $n" WARN
            return
        }
        if (-not $AllowMissing -and -not (Test-Path -LiteralPath $n -PathType Container)) { return }
        if (-not $found.ContainsKey($n)) { $found[$n] = $Source }
    }

    # 1. Стандартные каталоги
    @(
        "$PF\Autodesk", "$PF86\Autodesk",
        "$PF\Common Files\Autodesk Shared", "$PF86\Common Files\Autodesk Shared",
        "$PF\Common Files\Macrovision Shared\FLEXnet Publisher",
        "$PF86\Common Files\Macrovision Shared\FLEXnet Publisher",
        "$PD\Autodesk", "$PD\FLEXnet"
    ) | ForEach-Object { & $add $_ 'стандартный' $false }

    # 2. Каталоги верхнего уровня с Autodesk / Revit / pyRevit в имени
    foreach ($root in @($PF, $PF86, $PD)) {
        if (-not $root -or -not (Test-Path -LiteralPath $root)) { continue }
        Get-ChildItem -LiteralPath $root -Directory -Force -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -match $NamePattern } |
            ForEach-Object { & $add $_.FullName 'поиск по имени' $false }
    }

    # 3. Места установки из реестра (машина + все загруженные профили)
    $uninstallKeys = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'Registry::HKEY_USERS\*\Software\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )
    foreach ($key in $uninstallKeys) {
        try {
            Get-ItemProperty -Path $key -ErrorAction SilentlyContinue |
                Where-Object {
                    ($_.PSObject.Properties['Publisher'] -and $_.Publisher -match 'Autodesk') -or
                    ($_.PSObject.Properties['DisplayName'] -and $_.DisplayName -match $NamePattern)
                } |
                ForEach-Object {
                    if ($_.PSObject.Properties['InstallLocation'] -and $_.InstallLocation) {
                        & $add $_.InstallLocation 'реестр' $false
                    }
                }
        } catch {}
    }

    # 4. Профили ВСЕХ пользователей (а не только того, кто запустил скрипт)
    foreach ($prof in Get-UserProfilePaths) {
        $who = "профиль $(Split-Path -Leaf $prof)"
        @(
            'AppData\Roaming\Autodesk', 'AppData\Local\Autodesk',
            'AppData\Roaming\pyRevit', 'AppData\Roaming\pyRevit-Master', 'AppData\Local\pyRevit',
            'DC'   # Autodesk Desktop Connector
        ) | ForEach-Object { & $add (Join-Path $prof $_) $who $false }

        foreach ($sub in @('AppData\Roaming', 'AppData\Local')) {
            $r = Join-Path $prof $sub
            if (-not (Test-Path -LiteralPath $r)) { continue }
            Get-ChildItem -LiteralPath $r -Directory -Force -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -match $NamePattern } |
                ForEach-Object { & $add $_.FullName $who $false }
        }
    }

    # 5. Пользовательские пути из ExtraPaths.txt (могут не существовать локально, например UNC)
    if (Test-Path -LiteralPath $ExtraFile) {
        Get-Content -LiteralPath $ExtraFile -Encoding UTF8 |
            ForEach-Object { $_.Trim() } |
            Where-Object { $_ -and -not $_.StartsWith('#') } |
            ForEach-Object { & $add $_ 'ExtraPaths.txt' $true }
    }

    # Убрать вложенные пути: если исключён родитель, дочерний не нужен
    $result = New-Object 'System.Collections.Generic.Dictionary[string,string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($p in ($found.Keys | Sort-Object { $_.Length }, { $_ })) {
        $covered = $false
        foreach ($k in $result.Keys) {
            if ($p.StartsWith($k + '\', [StringComparison]::OrdinalIgnoreCase)) { $covered = $true; break }
        }
        if (-not $covered) { $result[$p] = $found[$p] }
    }
    return $result
}

# ------------------------------------------------------------------
# Defender
# ------------------------------------------------------------------
function Test-DefenderReady {
    $ok = $true
    try {
        $st = Get-MpComputerStatus -ErrorAction Stop
        if ($st.PSObject.Properties['AMRunningMode'] -and $st.AMRunningMode -and $st.AMRunningMode -ne 'Normal') {
            Write-AutodeskLog "Defender в режиме '$($st.AMRunningMode)' - вероятно, установлен сторонний антивирус. Исключения Autodesk нужно добавить и в него." WARN
        }
        if (-not $st.AntivirusEnabled) {
            Write-AutodeskLog 'Антивирус Defender выключен. Исключения сохранятся и начнут действовать после его включения.' WARN
        }
    } catch {
        Write-AutodeskLog "Служба Defender недоступна: $($_.Exception.Message)" ERROR
        $ok = $false
    }
    try {
        $v = (Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender' -Name DisableLocalAdminMerge -ErrorAction Stop).DisableLocalAdminMerge
        if ($v -eq 1) {
            Write-AutodeskLog 'Включена политика DisableLocalAdminMerge: локальные исключения игнорируются. Задайте их через GPO/Intune.' WARN
        }
    } catch {}
    return $ok
}

function Get-CurrentExclusions {
    $pref = Get-MpPreference -ErrorAction Stop
    $paths = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    $procs = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    @($pref.ExclusionPath)    | Where-Object { $_ } | ForEach-Object { [void]$paths.Add($_.TrimEnd('\')) }
    @($pref.ExclusionProcess) | Where-Object { $_ } | ForEach-Object { [void]$procs.Add($_) }
    return [pscustomobject]@{ Paths = $paths; Processes = $procs }
}

# ------------------------------------------------------------------
# Учёт добавленного скриптом
# ------------------------------------------------------------------
function Read-State {
    $paths = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    $procs = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($f in @($StateFile, $LegacyMarker)) {
        if (-not (Test-Path -LiteralPath $f)) { continue }
        try {
            $j = Get-Content -LiteralPath $f -Raw -Encoding UTF8 | ConvertFrom-Json
            @($j.Paths)     | Where-Object { $_ } | ForEach-Object { [void]$paths.Add(([string]$_).TrimEnd('\')) }
            @($j.Processes) | Where-Object { $_ } | ForEach-Object { [void]$procs.Add([string]$_) }
        } catch {
            throw "Не удалось прочитать файл учёта $f : $($_.Exception.Message)"
        }
    }
    return [pscustomobject]@{ Paths = $paths; Processes = $procs }
}

function Save-State {
    param($Paths, $Processes)
    if ($Script:Ctx.DryRun) { return }
    if (-not (Test-Path -LiteralPath $StateDir)) {
        New-Item -ItemType Directory -Path $StateDir -Force -ErrorAction Stop | Out-Null
    }
    if (-not $Paths.Count -and -not $Processes.Count) {
        Remove-Item -LiteralPath $StateFile -Force -ErrorAction SilentlyContinue
        return
    }
    [ordered]@{
        Paths     = @($Paths | Sort-Object)
        Processes = @($Processes | Sort-Object)
        Updated   = (Get-Date).ToString('o')
        Computer  = $env:COMPUTERNAME
    } | ConvertTo-Json -Depth 3 | Set-Content -LiteralPath $StateFile -Encoding UTF8
}

# ------------------------------------------------------------------
# Сеть AutoCAD / Revit и всех найденных EXE Autodesk.
# Отдельные правила AutoCAD / Revit действуют в Public; общий режим — во всех профилях.
# ------------------------------------------------------------------
$FirewallPrefix = 'ADE-NET'
$ProductExeNames = [ordered]@{
    'AutoCAD' = @('acad.exe','accoreconsole.exe')
    'Revit'   = @('Revit.exe','RevitWorker.exe')
}

function Get-ProductExecutables {
    param([ValidateSet('AutoCAD','Revit')][string]$Product)
    $names = $ProductExeNames[$Product]
    $roots = @($PF, $PF86) | Where-Object { $_ -and (Test-Path -LiteralPath $_) }
    $result = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)

    # Running processes give us exact paths cheaply.
    foreach ($n in $names) {
        $base = [IO.Path]::GetFileNameWithoutExtension($n)
        Get-Process -Name $base -ErrorAction SilentlyContinue | ForEach-Object {
            try { if ($_.Path) { [void]$result.Add($_.Path) } } catch {}
        }
    }

    # Search Autodesk installation trees, not the whole disk.
    foreach ($root in $roots) {
        foreach ($candidate in @((Join-Path $root 'Autodesk'), (Join-Path $root 'Autodesk\AutoCAD*'), (Join-Path $root 'Autodesk\Revit*'))) {
            Get-ChildItem -Path $candidate -File -Recurse -ErrorAction SilentlyContinue |
                Where-Object { $names -contains $_.Name } |
                ForEach-Object { [void]$result.Add($_.FullName) }
        }
    }
    return @($result | Sort-Object)
}

function Get-NetRuleName {
    param([string]$Product, [string]$Path)
    return "$FirewallPrefix-$Product-$(Get-AllRuleName $Path)-PUBLIC"
}

function Get-NetworkStatus {
    param([ValidateSet('AutoCAD','Revit')][string]$Product)
    $exe = @(Get-ProductExecutables $Product)
    $rules = @(Get-NetFirewallRule -ErrorAction SilentlyContinue | Where-Object { $_.Group -eq 'Autodesk Defender Exclusions - Network' -and $_.DisplayName -like "$FirewallPrefix-$Product-*" })
    $enabled = @($rules | Where-Object { $_.Enabled -eq 'True' }).Count
    [pscustomobject]@{
        Product=$Product; Executables=$exe; Rules=$rules; EnabledRules=$enabled
        State = if (-not $exe.Count) {'НЕ НАЙДЕН'} elseif ($enabled -gt 0) {'PUBLIC: БЛОК'} else {'PUBLIC: НЕТ'}
    }
}

function Set-ProductInternet {
    param(
        [ValidateSet('AutoCAD','Revit')][string]$Product,
        [bool]$Block
    )
    $exe = @(Get-ProductExecutables $Product)
    if ($Block -and -not $exe.Count) { Write-AutodeskLog "${Product}: исполняемые файлы не найдены." WARN; return }

    foreach ($path in $exe) { Write-Info "${Product}: $path" }
    if (Test-DryRun "${Product}: блокировка Public = $Block") { return }
    if (-not (Assert-Admin)) { return }
    if (-not (Confirm-Action -Question "${Product}: блокировка Public = $Block ?" -Danger)) { return }
    if ($Block) {
        foreach ($path in $exe) {
            $name = Get-NetRuleName $Product $path
            try {
                Get-NetFirewallRule -DisplayName $name -ErrorAction SilentlyContinue | Where-Object { $_.Group -eq 'Autodesk Defender Exclusions - Network' } | Remove-NetFirewallRule -ErrorAction SilentlyContinue
                # Правило блокирует весь исходящий трафик профиля Public; Private/Domain не затрагивает.
                New-NetFirewallRule -DisplayName $name -Group 'Autodesk Defender Exclusions - Network' `
                    -Direction Outbound -Action Block -Program $path -Profile Public -Enabled True `
                    -Description "Managed by Autodesk_Defender_Exclusions.ps1. Blocks $Product on Public networks only." | Out-Null
                Write-AutodeskLog "${Product}: Интернет заблокирован (Public): $path" OK
            } catch { Write-AutodeskLog "${Product}: не удалось создать правило для '$path': $($_.Exception.Message)" ERROR }
        }
    } else {
        try {
            Get-NetFirewallRule -ErrorAction SilentlyContinue |
                Where-Object { $_.Group -eq 'Autodesk Defender Exclusions - Network' -and $_.DisplayName -like "$FirewallPrefix-$Product-*" } |
                Remove-NetFirewallRule -ErrorAction Stop
            Write-AutodeskLog "${Product}: правила Public этого скрипта удалены." OK
        } catch { Write-AutodeskLog "${Product}: ошибка удаления сетевых правил: $($_.Exception.Message)" ERROR }
    }
}

function Show-NetworkStatus {
    Write-Host "`n=== СЕТЬ AUTODESK ===" -ForegroundColor Cyan
    foreach ($product in @('AutoCAD','Revit')) {
        $st = Get-NetworkStatus $product
        $color = if ($st.State -eq 'PUBLIC: БЛОК') {'Yellow'} elseif ($st.State -eq 'PUBLIC: НЕТ') {'Green'} else {'DarkGray'}
        Write-Host ("  {0,-8} : {1,-14} | найдено EXE: {2} | правил: {3}" -f $product,$st.State,$st.Executables.Count,$st.EnabledRules) -ForegroundColor $color
    }
    $allRules = @(Get-NetFirewallRule -Group $AllFirewallGroup -ErrorAction SilentlyContinue)
    Write-Host ("  Все Autodesk: активных правил {0} (все профили)" -f @($allRules | Where-Object { $_.Enabled -eq 'True' }).Count) -ForegroundColor Cyan
    Write-Host '  Отдельные правила AutoCAD / Revit действуют только в профиле Public.' -ForegroundColor DarkGray
}

$AllFirewallGroup = 'Autodesk Control Center - All Network'

function Get-AllAutodeskExecutables {
    $paths = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    $roots = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    # C:\Autodesk обычно содержит распакованные установщики, включая сторонние EXE.
    foreach ($base in @($PF, $PF86, $PD)) {
        if (-not $base -or -not (Test-Path -LiteralPath $base -PathType Container)) { continue }
        Get-ChildItem -LiteralPath $base -Directory -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -match '^(Autodesk|AutoCAD|Revit|3ds Max|Inventor|Maya|Navisworks|Adsk)' } |
            ForEach-Object { [void]$roots.Add($_.FullName) }
    }
    foreach ($base in @($PF, $PF86)) {
        foreach ($name in @('Common Files\Autodesk Shared', 'Common Files\Autodesk')) {
            $folder = Join-Path $base $name
            if (Test-Path -LiteralPath $folder -PathType Container) { [void]$roots.Add($folder) }
        }
    }
    foreach ($profile in Get-UserProfilePaths) {
        foreach ($name in @('AppData\Local\Autodesk', 'AppData\Roaming\Autodesk', 'AppData\Local\pyRevit', 'AppData\Roaming\pyRevit', 'DC')) {
            $folder = Join-Path $profile $name
            if (Test-Path -LiteralPath $folder -PathType Container) { [void]$roots.Add($folder) }
        }
    }
    foreach ($root in $roots) {
        Get-ChildItem -LiteralPath $root -Filter '*.exe' -File -Recurse -ErrorAction SilentlyContinue |
            ForEach-Object { [void]$paths.Add($_.FullName) }
    }
    return @($paths | Sort-Object)
}

function Get-AllRuleName {
    param([string]$Path)
    $bytes = [Text.Encoding]::UTF8.GetBytes($Path.ToUpperInvariant())
    $sha = [Security.Cryptography.SHA256]::Create()
    try { $hash = [BitConverter]::ToString($sha.ComputeHash($bytes)).Replace('-', '') }
    finally { $sha.Dispose() }
    return "ADE-ALL-$($hash.Substring(0, 32))"
}

function Set-AllAutodeskInternet {
    param([bool]$Block)
    if ($Block) {
        foreach ($path in @(Get-AllAutodeskExecutables)) { Write-Info "EXE: $path" }
    }
    if (Test-DryRun "все Autodesk: блокировка входящего и исходящего трафика во всех профилях = $Block") { return }
    if (-not (Assert-Admin)) { return }
    if (-not (Confirm-Action -Question "Все Autodesk: блокировка всех сетевых профилей = $Block ?" -Danger)) { return }
    if (-not $Block) {
        $rules = @(Get-NetFirewallRule -Group $AllFirewallGroup -ErrorAction SilentlyContinue) +
                 @(Get-NetFirewallRule -Group 'Autodesk Defender Exclusions - Network' -ErrorAction SilentlyContinue |
                     Where-Object { $_.DisplayName -like "$FirewallPrefix-*" })
        foreach ($rule in $rules) {
            try { $rule | Remove-NetFirewallRule -ErrorAction Stop; Write-AutodeskLog "Удалено сетевое правило: $($rule.DisplayName)" OK }
            catch { Write-AutodeskLog "Ошибка удаления правила '$($rule.DisplayName)': $($_.Exception.Message)" ERROR }
        }
        if (-not $rules.Count) { Write-AutodeskLog 'Сетевых правил этого скрипта нет.' INFO }
        return
    }
    $executables = @(Get-AllAutodeskExecutables)
    if (-not $executables.Count) { Write-AutodeskLog 'Исполняемые файлы Autodesk не найдены.' WARN; return }
    Write-Host ("`nНайдено программ Autodesk: {0}. Создаю правила для всех сетевых профилей..." -f $executables.Count) -ForegroundColor Cyan
    $added = 0
    $failed = 0
    foreach ($path in $executables) {
        # Как в Fab: блок и исходящих, и входящих соединений.
        foreach ($dir in @('Outbound', 'Inbound')) {
            $name = Get-AllRuleName $path
            if ($dir -eq 'Inbound') { $name = $name -replace '^ADE-ALL-', 'ADE-ALL-IN-' }
            try {
                $existing = Get-NetFirewallRule -Name $name -ErrorAction SilentlyContinue
                if ($existing) {
                    if ($existing.Group -ne $AllFirewallGroup) { throw 'Совпало имя чужого правила; оно не изменено.' }
                    $existing | Set-NetFirewallRule -Profile Any -Action Block -Enabled True -ErrorAction Stop
                    continue
                }
                New-NetFirewallRule -Name $name -DisplayName "Autodesk - $([IO.Path]::GetFileName($path))" -Group $AllFirewallGroup `
                    -Direction $dir -Action Block -Program $path -Profile Any -Enabled True `
                    -Description "Managed by Autodesk Control Center. Blocks $dir network traffic on all profiles." -ErrorAction Stop | Out-Null
                $added++
            } catch { Write-AutodeskLog "Ошибка правила ($dir) для '$path': $($_.Exception.Message)" ERROR; $failed++ }
        }
    }
    $level = if ($failed) { 'WARN' } else { 'OK' }
    Write-AutodeskLog ("Готово: найдено {0}, новых правил {1}, ошибок {2}. Повторите после установки новых версий Autodesk." -f $executables.Count, $added, $failed) $level
}

# Firewall App Blocker (sordum.org) из папки рядом со скриптом. Видит и правила этого скрипта.
function Start-Fab {
    $exe = if ([Environment]::Is64BitOperatingSystem) { 'Fab_x64.exe' } else { 'Fab.exe' }
    $fab = Get-ChildItem -LiteralPath $ScriptRoot -Directory -Filter 'Fab*' -ErrorAction SilentlyContinue |
        ForEach-Object { Join-Path $_.FullName $exe } |
        Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
    if (-not $fab) { Write-AutodeskLog "Fab не найден: ожидается папка 'Fab*\$exe' рядом со скриптом." WARN; return }
    if (Test-DryRun "запуск FAB: $fab") { return }
    if (-not (Assert-Admin)) { return }
    Start-Process -FilePath $fab -WorkingDirectory (Split-Path -Parent $fab)
    Write-AutodeskLog "Запущен Fab: $fab"
}

function Invoke-Install {
    if (-not $Script:Ctx.DryRun -and -not (Assert-Admin)) { return }
    if (-not (Test-DefenderReady)) { return }

    Write-Host "`nПоиск каталогов Autodesk..." -ForegroundColor Cyan
    $targets = Get-ExclusionTargets
    foreach ($p in ($targets.Keys | Sort-Object)) { Write-Info "Каталог: $p" }
    foreach ($p in $ProcessList) { Write-Info "Процесс: $p" }
    if (Test-DryRun 'добавление недостающих исключений Autodesk') { return }
    if (-not (Confirm-Action -Question 'Добавить исключения Autodesk? Проверка этих каталогов и файлов процессов будет отключена.' -Danger)) { return }

    $current = Get-CurrentExclusions
    $state   = Read-State

    $added = 0; $exists = 0; $failed = 0

    Write-Host "`n--- Каталоги ($($targets.Count)) ---" -ForegroundColor Cyan
    foreach ($p in $targets.Keys) {
        if ($current.Paths.Contains($p)) {
            Write-AutodeskLog "Уже есть: $p"
            $exists++
            continue
        }
        try {
            Add-MpPreference -ExclusionPath $p -ErrorAction Stop
            [void]$state.Paths.Add($p); Save-State $state.Paths $state.Processes
            Write-AutodeskLog "Добавлен каталог [$($targets[$p])]: $p" OK
            $added++
        } catch {
            Write-AutodeskLog "Ошибка добавления каталога '$p': $($_.Exception.Message)" ERROR
            $failed++
        }
    }

    Write-Host "`n--- Процессы ($($ProcessList.Count)) ---" -ForegroundColor Cyan
    foreach ($proc in $ProcessList) {
        if ($current.Processes.Contains($proc)) {
            Write-AutodeskLog "Уже есть: $proc"
            $exists++
            continue
        }
        try {
            Add-MpPreference -ExclusionProcess $proc -ErrorAction Stop
            [void]$state.Processes.Add($proc); Save-State $state.Paths $state.Processes
            Write-AutodeskLog "Добавлен процесс: $proc" OK
            $added++
        } catch {
            Write-AutodeskLog "Ошибка добавления процесса '$proc': $($_.Exception.Message)" ERROR
            $failed++
        }
    }

    Save-State $state.Paths $state.Processes
    if (Test-Path -LiteralPath $LegacyMarker) {
        Remove-Item -LiteralPath $LegacyMarker -Force -ErrorAction SilentlyContinue
        Write-AutodeskLog 'Старый файл учёта рядом со скриптом перенесён в ProgramData.'
    }

    # Контрольная проверка
    $after = Get-CurrentExclusions
    $missing = @($targets.Keys | Where-Object { -not $after.Paths.Contains($_) }) +
               @($ProcessList  | Where-Object { -not $after.Processes.Contains($_) })

    Write-Host ''
    Write-AutodeskLog ("Итог: добавлено {0}, уже было {1}, ошибок {2}." -f $added, $exists, $failed) $(if ($failed) { 'WARN' } else { 'OK' })
    if ($missing.Count) {
        Write-AutodeskLog "После установки не применились: $($missing -join '; ')" ERROR
    } else {
        Write-AutodeskLog 'Проверка пройдена: все исключения Autodesk активны.' OK
    }
}

function Invoke-Check {
    [void](Test-DefenderReady)
    $targets = Get-ExclusionTargets
    $current = Get-CurrentExclusions
    $state   = Read-State
    $miss = 0

    Write-Host "`n=== Каталоги Autodesk ===" -ForegroundColor Cyan
    foreach ($p in $targets.Keys) {
        if ($current.Paths.Contains($p)) { Write-Host "  [OK]  $p" -ForegroundColor Green }
        else { Write-Host "  [НЕТ] $p" -ForegroundColor Yellow; $miss++ }
    }

    Write-Host "`n=== Процессы Autodesk ===" -ForegroundColor Cyan
    foreach ($proc in $ProcessList) {
        if ($current.Processes.Contains($proc)) { Write-Host "  [OK]  $proc" -ForegroundColor Green }
        else { Write-Host "  [НЕТ] $proc" -ForegroundColor Yellow; $miss++ }
    }

    $otherPaths = @($current.Paths | Where-Object { -not $targets.ContainsKey($_) } | Sort-Object)
    $otherProcs = @($current.Processes | Where-Object { $ProcessList -notcontains $_ } | Sort-Object)
    if ($otherPaths.Count -or $otherProcs.Count) {
        Write-Host "`n=== Прочие исключения Defender ===" -ForegroundColor DarkCyan
        $otherPaths | ForEach-Object { Write-Host "  $_" }
        $otherProcs | ForEach-Object { Write-Host "  $_ (процесс)" }
    }

    Write-Host ''
    if ($miss) { Write-Host "Не хватает исключений: $miss. Выполните установку (пункт 1)." -ForegroundColor Yellow }
    else       { Write-Host 'Все исключения Autodesk на месте.' -ForegroundColor Green }
    Write-Host ("Добавлено этим скриптом: каталогов {0}, процессов {1}. Учёт: {2}" -f $state.Paths.Count, $state.Processes.Count, $StateFile) -ForegroundColor DarkGray
}

function Invoke-Remove {
    if (-not $Script:Ctx.DryRun -and -not (Assert-Admin)) { return }
    $state = Read-State
    if (-not $state.Paths.Count -and -not $state.Processes.Count) {
        Write-AutodeskLog 'Нет исключений, добавленных этим скриптом. Чужие исключения не трогаю.' WARN
        return
    }

    foreach ($p in $state.Paths) { Write-Info "Удалить каталог: $p" }
    foreach ($p in $state.Processes) { Write-Info "Удалить процесс: $p" }
    if (Test-DryRun 'удаление только учтённых исключений Autodesk') { return }
    if (-not (Confirm-Action -Question 'Удалить учтённые исключения Autodesk?')) { return }

    $leftPaths = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    $leftProcs = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)

    foreach ($p in @($state.Paths)) {
        try {
            Remove-MpPreference -ExclusionPath $p -ErrorAction Stop
            Write-AutodeskLog "Удалён каталог: $p" OK
        } catch {
            Write-AutodeskLog "Не удалось удалить каталог '$p': $($_.Exception.Message)" ERROR
            [void]$leftPaths.Add($p)
        }
    }
    foreach ($p in @($state.Processes)) {
        try {
            Remove-MpPreference -ExclusionProcess $p -ErrorAction Stop
            Write-AutodeskLog "Удалён процесс: $p" OK
        } catch {
            Write-AutodeskLog "Не удалось удалить процесс '$p': $($_.Exception.Message)" ERROR
            [void]$leftProcs.Add($p)
        }
    }

    Save-State $leftPaths $leftProcs     # неудалённое остаётся в учёте для повторной попытки
    Remove-Item -LiteralPath $LegacyMarker -Force -ErrorAction SilentlyContinue

    if ($leftPaths.Count -or $leftProcs.Count) {
        Write-AutodeskLog 'Удалено не всё - повторите удаление позже.' WARN
    } else {
        Write-AutodeskLog 'Удалены все исключения, добавленные этим скриптом.' OK
    }
}


    $items = @(
        [pscustomobject]@{ Key='1'; Title='Добавить исключения Defender'; Desc='Каталоги, профили пользователей, процессы Autodesk' },
        [pscustomobject]@{ Key='2'; Title='Проверить исключения'; Desc='Найденные, отсутствующие и сторонние исключения' },
        [pscustomobject]@{ Key='3'; Title='Удалить учтённые исключения'; Desc='Только добавленные этим скриптом или исходной утилитой' },
        [pscustomobject]@{ Key='4'; Title='Состояние сети'; Desc='Правила Autodesk в Windows Firewall' },
        [pscustomobject]@{ Key='5'; Title='AutoCAD: блокировать Public'; Desc='Исходящий трафик' },
        [pscustomobject]@{ Key='6'; Title='AutoCAD: удалить правила Public'; Desc='Удаление блокировок утилиты' },
        [pscustomobject]@{ Key='7'; Title='Revit: блокировать Public'; Desc='Исходящий трафик' },
        [pscustomobject]@{ Key='8'; Title='Revit: удалить правила Public'; Desc='Удаление блокировок утилиты' },
        [pscustomobject]@{ Key='a'; Title='Все Autodesk: блокировать сеть'; Desc='Все найденные EXE, оба направления, все профили' },
        [pscustomobject]@{ Key='b'; Title='Все Autodesk: удалить блокировки'; Desc='Только правила утилиты' },
        [pscustomobject]@{ Key='f'; Title='Открыть Firewall App Blocker'; Desc='Необязательно: папка Fab* рядом со скриптом' }
    )
    while ($true) {
        $choice = Show-Menu -Items $items -Title 'Autodesk: Defender и сеть' -BackText 'Назад'
        if ($choice -eq '0') { return }
        try {
            switch ($choice) {
                '1' { Invoke-Install }
                '2' { Invoke-Check }
                '3' { Invoke-Remove }
                '4' { Show-NetworkStatus }
                '5' { Set-ProductInternet AutoCAD $true }
                '6' { Set-ProductInternet AutoCAD $false }
                '7' { Set-ProductInternet Revit $true }
                '8' { Set-ProductInternet Revit $false }
                'a' { Set-AllAutodeskInternet $true }
                'b' { Set-AllAutodeskInternet $false }
                'f' { Start-Fab }
            }
        } catch { Write-AutodeskLog $_.Exception.Message ERROR }
        Wait-Menu
    }
}

function Invoke-SettingsMenu {
    while ($true) {
        $dryText = if ($Script:Ctx.DryRun) { 'включён' } else { 'выключен' }
        $yesText = if ($Script:Ctx.AssumeYes) { 'включён' } else { 'выключен' }

        $items = @(
            [pscustomobject]@{ Key = '1'; Title = "Сухой прогон: $dryText"; Desc = 'Ничего не удаляется и не изменяется, только показывается план' },
            [pscustomobject]@{ Key = '2'; Title = "Без подтверждений: $yesText"; Desc = 'Опасно: операции выполняются сразу' },
            [pscustomobject]@{ Key = '3'; Title = 'Открыть папку логов'; Desc = $(if ($Script:Ctx.LogPath) { Split-Path $Script:Ctx.LogPath -Parent } else { 'лог не пишется' }) }
        )

        $choice = Show-Menu -Items $items -Title 'настройки сессии' -BackText 'Назад'
        switch ($choice) {
            '0' { return }
            '1' { $Script:Ctx.DryRun = -not $Script:Ctx.DryRun }
            '2' {
                if (-not $Script:Ctx.AssumeYes) {
                    Write-Banner
                    Write-Blank
                    Write-Warn 'Режим без подтверждений выполняет удаление сразу, без вопросов.'
                    if (Confirm-Action -Question 'Точно включить?' -Danger) { $Script:Ctx.AssumeYes = $true }
                }
                else { $Script:Ctx.AssumeYes = $false }
            }
            '3' {
                if ($Script:Ctx.LogPath) {
                    Start-Process explorer.exe (Split-Path $Script:Ctx.LogPath -Parent)
                }
            }
        }
    }
}

function Invoke-ModuleByKey {
    param([string]$Key)

    switch ($Key) {
        'status'   { Invoke-ModuleStatus }
        'iis'      { Invoke-ModuleIis }
        'maxbytes' { Invoke-ModuleMaxBytes }
        'accel'    { Invoke-ModuleAccelerator }
        'clean'    { Invoke-ModuleClean }
        'backups'  { Invoke-ModuleBackups }
        'autodesk' { Invoke-ModuleAutodesk }
    }
}

function Invoke-MainMenu {
    $items = @(
        [pscustomobject]@{ Key = '1'; Title = 'Сводка окружения'; Desc = 'Revit, Revit Server, службы, акселераторы, IIS' },
        [pscustomobject]@{ Key = '2'; Title = 'IIS для Revit Server'; Desc = 'Роли Windows Server, ASP.NET 4.8, WCF HTTP/TCP, IIS 6 compat' },
        [pscustomobject]@{ Key = '3'; Title = 'maxBytesPerRead'; Desc = 'web.config Revit Server: 102400 / 4096 / своё значение' },
        [pscustomobject]@{ Key = '4'; Title = 'Revit Server Accelerator'; Desc = 'Переменные RSACCELERATOR2018-2026' },
        [pscustomobject]@{ Key = '5'; Title = 'Очистка Revit'; Desc = 'Следы установки, реестр, AdskLicensing' },
        [pscustomobject]@{ Key = '6'; Title = 'Backup-папки и журналы'; Desc = 'Поиск *_backup с парным .rvt, старые журналы, CSV-отчёт' },
        [pscustomobject]@{ Key = '7'; Title = 'Autodesk: Defender и сеть'; Desc = 'Исключения, откат, сетевые блокировки, FAB' },
        [pscustomobject]@{ Key = '9'; Title = 'Настройки сессии'; Desc = 'Сухой прогон, подтверждения, логи' }
    )

    $map = @{
        '1' = 'status'; '2' = 'iis'; '3' = 'maxbytes'; '4' = 'accel'; '5' = 'clean'; '6' = 'backups'; '7' = 'autodesk'
    }

    while ($true) {
        $choice = Show-Menu -Items $items -Title 'что делаем' -BackText 'Выход'

        if ($choice -eq '0') { return }
        if ($choice -eq '9') { Invoke-SettingsMenu; continue }
        if ($map.ContainsKey($choice)) {
            try { Invoke-ModuleByKey -Key $map[$choice] }
            catch {
                Write-Blank
                Write-Fail "Непредвиденная ошибка: $($_.Exception.Message)"
                Write-Log "FATAL $($_.Exception.ToString())"
                Wait-Menu
            }
        }
    }
}

# ============================================================================
#  Точка входа
# ============================================================================

Initialize-Console
$Script:Ctx.Vt = Enable-VirtualTerminal
Initialize-Palette
$Script:Ctx.IsAdmin = Test-IsAdministrator
Initialize-Log

Write-Log "$Script:AppName v$Script:AppVersion started"
Write-Log "host=$env:COMPUTERNAME user=$env:USERNAME admin=$($Script:Ctx.IsAdmin) dryrun=$($Script:Ctx.DryRun) ps=$($PSVersionTable.PSVersion)"

try {
    if ($Module) {
        Invoke-ModuleByKey -Key $Module
    }
    else {
        Show-StartupAnimation
        Invoke-MainMenu
        Write-Banner
        Write-Blank
        Write-Bullet 'Сессия завершена.'
        if ($Script:Ctx.LogPath) { Write-Info "Лог: $($Script:Ctx.LogPath)" }
        Write-Blank
    }
}
catch {
    Write-Blank
    Write-Fail "Критическая ошибка: $($_.Exception.Message)"
    Write-Log "FATAL $($_.Exception.ToString())"
    exit 1
}
finally {
    Write-Log "$Script:AppName finished"
    Write-Host $Script:C.Reset -NoNewline
}
