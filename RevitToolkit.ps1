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
    Запуск конкретного модуля без меню: status | iis | maxbytes | accel | clean | backups | autodesk | rsn | license

.PARAMETER DryRun
    Сухой прогон: всё ищется и показывается, но ничего не удаляется и не меняется.

.PARAMETER Language
    Язык интерфейса: ru | en. Без параметра используется сохранённый выбор;
    при первом интерактивном запуске предлагается выбрать язык.

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
    [ValidateSet('', 'status', 'iis', 'maxbytes', 'accel', 'clean', 'backups', 'autodesk', 'rsn', 'license')]
    [string]$Module = '',

    [ValidateSet('', 'ru', 'en')]
    [string]$Language = '',

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
$Script:UiLanguage = 'ru'
$Script:LanguageFile = Join-Path $env:LOCALAPPDATA 'RevitToolkit\language.txt'

function Get-UiText {
    param([string]$Russian, [string]$English)
    if ($Script:UiLanguage -eq 'en') { return $English }
    return $Russian
}

function Save-UiLanguage {
    try {
        $directory = Split-Path -Parent $Script:LanguageFile
        New-Item -ItemType Directory -Path $directory -Force -ErrorAction Stop | Out-Null
        Set-Content -LiteralPath $Script:LanguageFile -Value $Script:UiLanguage -Encoding ASCII -ErrorAction Stop
    } catch {
        Write-Warn (Get-UiText 'Не удалось сохранить язык. Выбор действует до конца сессии.' 'Could not save language. The selection applies to this session only.')
    }
}

function Select-UiLanguage {
    Write-Banner
    Write-Blank
    Write-Host '  Язык интерфейса / Interface language'
    Write-Host '  [1] Русский'
    Write-Host '  [2] English'
    while ($true) {
        $answer = Read-Host '  1 / 2'
        switch ($answer.Trim().ToLowerInvariant()) {
            { $_ -in @('1', 'ru') } { $Script:UiLanguage = 'ru'; Save-UiLanguage; return }
            { $_ -in @('2', 'en') } { $Script:UiLanguage = 'en'; Save-UiLanguage; return }
        }
        Write-Host '  Выберите 1 или 2 / Choose 1 or 2'
    }
}

function Initialize-UiLanguage {
    if ($Language) { $Script:UiLanguage = $Language; return }
    if (Test-Path -LiteralPath $Script:LanguageFile -PathType Leaf) {
        try {
            $saved = (Get-Content -LiteralPath $Script:LanguageFile -Raw -ErrorAction Stop).Trim()
            if ($saved -in @('ru', 'en')) { $Script:UiLanguage = $saved.ToLowerInvariant(); return }
        } catch { }
    }
    # Piped/automated runs use Russian unless -Language is supplied.
    try { if ([Console]::IsInputRedirected) { return } } catch { return }
    Select-UiLanguage
}

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
    $visible = [Console]::CursorVisible
    try {
        [Console]::CursorVisible = $false
        for ($phase = 0; $phase -lt 12; $phase++) {
            Write-Banner -LogoPhase $phase
            if ([Console]::KeyAvailable) { break }
            Start-Sleep -Milliseconds 30
        }
    } finally {
        [Console]::CursorVisible = $visible
    }
}

function Get-ToolkitLogo {
    if ($Ascii) {
        return @(' ____       ______ ', '|  _ \     |__  __|', '| |_) |  /    | |  ', '|  _ <  /     | |  ', '|_| \_\       |_|  ', '                   ')
    }
    return @('██████╗   ╱ ████████╗', '██╔══██╗ ╱  ╚══██╔══╝', '██████╔╝╱      ██║   ', '██╔══██╗       ██║   ', '██║  ██║       ██║   ', '╚═╝  ╚═╝       ╚═╝   ')
}

function Format-LogoRow {
    param([string]$Row, [int]$Phase = -1)
    if ($Phase -lt 0 -or -not $Script:Ctx.Vt) { return $Script:C.Cyan + $Row + $Script:C.Reset }
    $builder = New-Object Text.StringBuilder
    for ($i = 0; $i -lt $Row.Length; $i++) {
        $distance = [Math]::Abs($i - ($Phase * 2))
        $color = if ($distance -le 1) { $Script:C.Text } elseif ($distance -le 4) { $Script:C.Cyan } else { $Script:C.Blue }
        [void]$builder.Append($color).Append($Row[$i])
    }
    [void]$builder.Append($Script:C.Reset)
    return $builder.ToString()
}

function Write-Banner {
    param([int]$LogoPhase = -1)
    if ($Script:Ctx.Vt -and (Test-InteractiveKeys)) {
        Write-Host ("$($Script:ESC)[H$($Script:ESC)[J") -NoNewline
    } else { Clear-Host }
    try {
        if ([Console]::WindowWidth -gt 20) { $Script:Ctx.Width = [Math]::Min([Console]::WindowWidth - 2, 110) }
    } catch { }
    $width = $Script:Ctx.Width - 4
    $mode = if ($Script:Ctx.DryRun) { 'DRY RUN' } else { 'LIVE' }
    $rights = if ($Script:Ctx.IsAdmin) { 'ADMIN' } else { 'USER' }
    $height = 0
    try { $height = [Console]::WindowHeight } catch { }
    $large = $Script:Ctx.Width -ge 68 -and $height -ge 30
    $inside = $Script:Ctx.Width - 6
    $rail = if ($Ascii) { '-' } else { [string][char]0x2500 }
    $edge = if ($Ascii) { '|' } else { [string][char]0x2502 }
    $tl = if ($Ascii) { '+' } else { [string][char]0x256D }
    $tr = if ($Ascii) { '+' } else { [string][char]0x256E }
    $bl = if ($Ascii) { '+' } else { [string][char]0x2570 }
    $br = if ($Ascii) { '+' } else { [string][char]0x256F }
    Write-Blank
    Write-Host ('  ' + $Script:C.Blue + $tl + ($rail * $inside) + $tr + $Script:C.Reset)
    if ($large) {
        $logo = @(Get-ToolkitLogo)
        $labels = @('REVIT / TOOLKIT', 'BIM OPERATIONS CONSOLE', '', (Get-UiText 'МОДЕЛИ / СЕРВЕРЫ / СИСТЕМА' 'MODELS / SERVERS / SYSTEM'), "VERSION $Script:AppVersion", 'R / T  ::  AUTODESK WORKSPACE')
        for ($i = 0; $i -lt $logo.Count; $i++) {
            $row = ' ' + $logo[$i].PadRight(26)
            $label = (Format-UiText $labels[$i] ($inside - 28)).PadRight($inside - 28) + ' '
            Write-Host ('  ' + $Script:C.Blue + $edge + (Format-LogoRow $row -Phase $LogoPhase) + $Script:C.Bold + $Script:C.Text + $label + $Script:C.Reset + $Script:C.Blue + $edge + $Script:C.Reset)
        }
        $Script:BannerRows = 12
    } else {
        $label = (Format-UiText "R / T   REVIT TOOLKIT   v$Script:AppVersion" ($inside - 2)).PadRight($inside - 2)
        Write-Host ('  ' + $Script:C.Blue + $edge + ' ' + $Script:C.Cyan + $Script:C.Bold + $label + $Script:C.Reset + ' ' + $Script:C.Blue + $edge + $Script:C.Reset)
        $Script:BannerRows = 7
    }
    Write-Host ('  ' + $Script:C.Blue + $bl + ($rail * $inside) + $br + $Script:C.Reset)
    $color = if ($Script:Ctx.DryRun) { $Script:C.Violet } else { $Script:C.Yellow }
    $languageLabel = if ($Script:UiLanguage -eq 'en') { 'EN' } else { 'RU' }
    Write-Host ('  ' + $color + "[$mode]" + $Script:C.Reset + $Script:C.Muted + "  [$rights]  [$languageLabel]  PS $($PSVersionTable.PSVersion)" + $Script:C.Reset)
    Write-Meta (Format-UiText "WORKSTATION / $env:COMPUTERNAME" $width)
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
        [string]$BackText = (Get-UiText 'Выход' 'Exit')
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
                try { $rows = [Math]::Max(1, [Math]::Min($Items.Count, [Console]::WindowHeight - $Script:BannerRows - 10)) } catch { }
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
            if ($rows -lt $Items.Count) { Write-Meta ((Get-UiText "{0}/{1}  ·  остальные пункты: стрелки" "{0}/{1}  ·  more items: arrow keys") -f ($index + 1), $Items.Count) }
            Write-Blank
            Write-Meta (Get-UiText "0  $BackText   /   стрелки + Enter   /   клавиша пункта" "0  $BackText   /   arrows + Enter   /   item key")
            $firstFrame = $false
            if (-not $useKeys) {
                $answer = (Read-Host (Get-UiText '  Выбор' '  Choice')).Trim()
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
        Write-Info (Get-UiText "$Question -> да (режим -Yes)" "$Question -> yes (-Yes mode)")
        return $true
    }

    if ($Script:Ctx.DryRun) {
        Write-Info (Get-UiText "$Question -> пропуск (сухой прогон)" "$Question -> skipped (dry run)")
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
        [string]$Title = (Get-UiText 'Выберите позиции' 'Select items')
    )

    Write-Blank
    Write-Bullet $Title
    Write-Blank
    for ($i = 0; $i -lt $Options.Count; $i++) {
        Write-Host ("    " + $Script:C.Muted + ("[{0}]" -f ($i + 1)) + $Script:C.Reset + ' ' + $Script:C.Text + $Options[$i] + $Script:C.Reset)
    }
    Write-Host ("    " + $Script:C.Muted + "[A]" + $Script:C.Reset + ' ' + $Script:C.Text + (Get-UiText 'Все' 'All') + $Script:C.Reset)

    $raw = Read-Text -Label (Get-UiText 'Номера через запятую или A' 'Comma-separated numbers or A')
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
    Write-Host ("  " + $Script:C.Faint + (Get-UiText "Enter $($Script:G.Arrow) вернуться в меню" "Enter $($Script:G.Arrow) return to menu") + $Script:C.Reset) -NoNewline
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
        if (-not $Quiet) { Write-Ok ((Get-UiText "готово за {0:N1}s" "done in {0:N1}s") -f $sw.Elapsed.TotalSeconds) }
        return $result
    }
    catch {
        $sw.Stop()
        Write-Fail ((Get-UiText "ошибка: " "error: ") + $_.Exception.Message)
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
    param([string]$Reason = (Get-UiText 'Модуль требует прав администратора.' 'This module requires administrator privileges.'))
    if ($Script:Ctx.IsAdmin) { return $true }

    Write-Blank
    Write-Fail $Reason
    Write-Info (Get-UiText 'Перезапустите PowerShell от имени администратора:' 'Restart PowerShell as administrator:')
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
    Write-Prompt (Get-UiText 'сводка окружения' 'environment overview')
    Write-LogHeader 'STATUS'

    Write-Blank
    Write-Bullet (Get-UiText 'Система' 'System')
    try {
        $os = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop
        Write-Kv (Get-UiText 'ОС' 'OS') "$($os.Caption) ($($os.Version))"
    }
    catch { Write-Kv (Get-UiText 'ОС' 'OS') (Get-UiText 'не определена' 'unknown') $Script:C.Yellow }
    Write-Kv (Get-UiText 'Тип' 'Type') $(if (Test-IsWindowsServer) { 'Windows Server' } else { (Get-UiText 'Клиентская Windows' 'Windows client') })
    Write-Kv 'PowerShell' $PSVersionTable.PSVersion.ToString()
    Write-Kv (Get-UiText 'Права' 'Privileges') $(if ($Script:Ctx.IsAdmin) { (Get-UiText 'администратор' 'administrator') } else { (Get-UiText 'обычный пользователь' 'standard user') }) $(if ($Script:Ctx.IsAdmin) { $Script:C.Green } else { $Script:C.Yellow })
    Write-Kv (Get-UiText 'Лог сессии' 'Session log') $(if ($Script:Ctx.LogPath) { $Script:Ctx.LogPath } else { (Get-UiText 'не пишется' 'unavailable') })

    Write-Blank
    Write-Bullet (Get-UiText 'Установленные версии Revit' 'Installed Revit versions')
    $versions = @(Invoke-Step -Text 'scan registry + program files' -Action { Get-DetectedRevitVersion } -Quiet)
    if ($versions.Count -eq 0) {
        Write-Info (Get-UiText 'не найдено' 'not found')
    }
    else {
        foreach ($v in $versions) {
            $accel = Get-AcceleratorValue -Version ([int]$v)
            $accelText = if ([string]::IsNullOrWhiteSpace($accel)) { (Get-UiText 'accelerator не задан' 'accelerator not set') } else { "accelerator: $accel" }
            Write-Kv "Revit $v" $accelText $(if ($accel) { $Script:C.Green } else { $Script:C.Muted })
        }
    }

    Write-Blank
    Write-Bullet 'Revit Server'
    $servers = @(Get-RevitServerInstall)
    if ($servers.Count -eq 0) {
        Write-Info (Get-UiText 'не установлен' 'not installed')
    }
    else {
        foreach ($server in $servers) {
            $configs = @(Get-RevitServerConfigFile -ServerFolder $server)
            $values = @()
            foreach ($config in $configs) {
                $value = Get-MaxBytesPerRead -ConfigPath $config
                if ($value) { $values += $value }
            }
            $valueText = if ($values.Count -eq 0) { (Get-UiText 'maxBytesPerRead не найден' 'maxBytesPerRead not found') } else { 'maxBytesPerRead: ' + (($values | Sort-Object -Unique) -join ' / ') }
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
        Write-Bullet (Get-UiText 'Компоненты IIS для Revit Server' 'IIS features for Revit Server')
        $required = Get-IisFeatureList
        try {
            Import-Module ServerManager -ErrorAction Stop
            $state = Get-WindowsFeature -Name $required -ErrorAction Stop
            $missing = @($state | Where-Object { $_.InstallState -ne 'Installed' })
            if ($missing.Count -eq 0) {
                Write-Ok (Get-UiText "все $($required.Count) компонентов включены" "all $($required.Count) features enabled")
            }
            else {
                Write-Warn (Get-UiText "не включено: $($missing.Count) из $($required.Count)" "disabled: $($missing.Count) of $($required.Count)")
                foreach ($item in $missing) { Write-Kv "  $($item.Name)" $item.InstallState $Script:C.Yellow }
            }
        }
        catch { Write-Info (Get-UiText 'не удалось прочитать состояние ролей' 'could not read feature status') }
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
    Write-Prompt (Get-UiText 'установка IIS и компонентов для Revit Server' 'install IIS and Revit Server features')
    Write-LogHeader 'IIS INSTALL'

    if (-not (Test-IsWindowsServer)) {
        Write-Blank
        Write-Fail (Get-UiText 'Это не Windows Server. Модуль использует Install-WindowsFeature и работает только на серверной ОС.' 'This is not Windows Server. This module uses Install-WindowsFeature and requires a server OS.')
        Write-Info (Get-UiText 'На клиентской Windows компоненты IIS ставятся через Enable-WindowsOptionalFeature / DISM.' 'On Windows clients, install IIS features using Enable-WindowsOptionalFeature / DISM.')
        Wait-Menu
        return
    }

    if (-not (Assert-Admin -Reason (Get-UiText 'Установка ролей Windows требует прав администратора.' 'Installing Windows features requires administrator privileges.'))) { Wait-Menu; return }

    $features = Get-IisFeatureList
    Import-Module ServerManager -ErrorAction SilentlyContinue

    Write-Blank
    Write-Tool 'reading' (Get-UiText 'состояние ролей Windows Server' 'Windows Server feature status')

    $before = $null
    try { $before = Get-WindowsFeature -Name $features -ErrorAction Stop }
    catch {
        Write-Fail (Get-UiText "не удалось прочитать список ролей: $($_.Exception.Message)" "could not read feature list: $($_.Exception.Message)")
        Wait-Menu
        return
    }

    Write-Blank
    Write-Bullet (Get-UiText 'Состояние ДО установки' 'Status BEFORE installation')
    Write-Blank
    foreach ($item in $before) {
        $color = if ($item.InstallState -eq 'Installed') { $Script:C.Green } else { $Script:C.Muted }
        Write-Kv $item.Name ([string]$item.InstallState) $color
    }

    $missing = @($before | Where-Object { $_.InstallState -ne 'Installed' })

    Write-Blank
    if ($missing.Count -eq 0) {
        Write-Ok (Get-UiText 'все требуемые компоненты уже включены, установка не нужна' 'all required features are already enabled; no installation needed')
        Write-Blank
        if (Confirm-Action -Question (Get-UiText 'Всё равно перезапустить IIS (iisreset)?' 'Restart IIS anyway (iisreset)?')) {
            Invoke-Step -Text 'iisreset' -Action { iisreset | ForEach-Object { Write-Log "     $_" } } | Out-Null
        }
        Wait-Menu
        return
    }

    Write-Bullet (Get-UiText "Будет включено компонентов: $($missing.Count)" "Features to enable: $($missing.Count)")
    Write-Blank
    foreach ($item in $missing) { Write-Add "$($item.Name)  $($Script:G.Dot)  $($item.DisplayName)" }

    Write-Blank
    if (Test-DryRun "Install-WindowsFeature -Name $($missing.Name -join ', ') -IncludeManagementTools") {
        Wait-Menu
        return
    }

    if (-not (Confirm-Action -Question (Get-UiText 'Запустить установку компонентов?' 'Install the features?'))) {
        Write-Info (Get-UiText 'Отменено.' 'Cancelled.')
        Wait-Menu
        return
    }

    Write-Blank
    $result = Invoke-Step -Text 'Install-WindowsFeature -IncludeManagementTools' -Action {
        $output = Install-WindowsFeature -Name $features -IncludeManagementTools -ErrorAction Stop
        $output
    }

    if ($null -eq $result) {
        Write-Fail (Get-UiText 'Установка завершилась с ошибкой. Перезагрузка не выполняется.' 'Installation failed. No restart will be performed.')
        Wait-Menu
        return
    }

    Write-Blank
    Write-Bullet (Get-UiText 'Состояние ПОСЛЕ установки' 'Status AFTER installation')
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
        Write-Warn (Get-UiText "Не включено компонентов: $($stillMissing.Count). Перезагрузка не выполняется автоматически." "Features still disabled: $($stillMissing.Count). No automatic restart.")
        Wait-Menu
        return
    }

    Write-Ok (Get-UiText 'Все требуемые компоненты включены' 'All required features are enabled')

    Write-Blank
    Invoke-Step -Text 'iisreset' -Action { iisreset | ForEach-Object { Write-Log "     $_" } } | Out-Null

    Write-Blank
    if ($result.RestartNeeded -eq 'Yes' -or $result.RestartNeeded -eq $true) {
        Write-Warn (Get-UiText 'Windows сообщает, что требуется перезагрузка.' 'Windows reports that a restart is required.')
    }

    if (Confirm-Action -Question (Get-UiText 'Перезагрузить сервер через 60 секунд?' 'Restart the server in 60 seconds?') -Danger) {
        Write-Info (Get-UiText 'Отменить можно командой: shutdown /a' 'Cancel with: shutdown /a')
        shutdown.exe /r /t 60 /c (Get-UiText "Revit Toolkit: IIS-компоненты для Revit Server установлены." "Revit Toolkit: IIS features for Revit Server installed.")
        Write-Ok (Get-UiText 'Перезагрузка запланирована' 'Restart scheduled')
    }
    else {
        Write-Info (Get-UiText 'Перезагрузите сервер вручную, чтобы компоненты применились.' 'Restart the server manually to apply the features.')
    }

    Wait-Menu
}

# ============================================================================
#  МОДУЛЬ 2: maxBytesPerRead в web.config Revit Server
#  (RevitServer-MaxBytesPerRead-Fix)
# ============================================================================

function Invoke-ModuleMaxBytes {
    Write-Banner
    Write-Prompt (Get-UiText 'настройка maxBytesPerRead в Revit Server' 'configure Revit Server maxBytesPerRead')
    Write-LogHeader 'MAXBYTESPERREAD'

    Write-Blank
    Write-Tool 'reading' 'C:\Program Files\Autodesk\Revit Server*'

    $servers = @(Get-RevitServerInstall)
    if ($servers.Count -eq 0) {
        Write-Blank
        Write-Fail (Get-UiText 'Revit Server не найден.' 'Revit Server not found.')
        Wait-Menu
        return
    }

    Write-Blank
    Write-Bullet (Get-UiText "Найдено установок: $($servers.Count)" "Installations found: $($servers.Count)")
    Write-Blank

    $labels = @()
    foreach ($server in $servers) {
        $configs = @(Get-RevitServerConfigFile -ServerFolder $server)
        $values = @()
        foreach ($config in $configs) {
            $value = Get-MaxBytesPerRead -ConfigPath $config
            if ($value) { $values += $value }
        }
        $valueText = if ($values.Count -eq 0) { (Get-UiText 'значение не найдено' 'value not found') } else { (($values | Sort-Object -Unique) -join ' / ') }
        $labels += ("{0}   [web.config: {1}, maxBytesPerRead: {2}]" -f $server.Name, $configs.Count, $valueText)
    }

    $selected = Read-Selection -Options $labels -Title (Get-UiText 'Какие версии обрабатывать' 'Versions to process')
    if ($selected.Count -eq 0) {
        Write-Blank
        Write-Info (Get-UiText 'Ничего не выбрано.' 'Nothing selected.')
        Wait-Menu
        return
    }

    $modes = @(
        [pscustomobject]@{ Key = '1'; Title = (Get-UiText 'Установить 102400' 'Set 102400'); Desc = (Get-UiText 'Рекомендуется для больших моделей и медленных каналов' 'Recommended for large models and slow connections') },
        [pscustomobject]@{ Key = '2'; Title = (Get-UiText 'Вернуть значение Autodesk 4096' 'Restore Autodesk default: 4096'); Desc = (Get-UiText 'Откат к стандартной конфигурации' 'Restore default configuration') },
        [pscustomobject]@{ Key = '3'; Title = (Get-UiText 'Своё значение' 'Custom value'); Desc = (Get-UiText 'Ввести число вручную' 'Enter a number manually') }
    )

    $modeKey = Show-Menu -Items $modes -Title (Get-UiText 'режим изменения' 'change mode') -BackText (Get-UiText 'Отмена' 'Cancel')
    if ($modeKey -eq '0') { return }

    $newValue = switch ($modeKey) {
        '1' { '102400' }
        '2' { '4096' }
        '3' {
            $raw = Read-Text -Label (Get-UiText 'Значение maxBytesPerRead' 'maxBytesPerRead value') -Hint (Get-UiText 'Целое число, например 65536' 'An integer, e.g. 65536')
            if ($raw -notmatch '^\d+$') { $null } else { $raw }
        }
    }

    if (-not $newValue) {
        Write-Blank
        Write-Fail (Get-UiText 'Некорректное значение.' 'Invalid value.')
        Wait-Menu
        return
    }

    if (-not (Assert-Admin -Reason (Get-UiText 'Изменение web.config и остановка служб требуют прав администратора.' 'Editing web.config and stopping services require administrator privileges.'))) { Wait-Menu; return }

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

    Write-Bullet (Get-UiText "Файлов к изменению: $($targets.Count)" "Files to change: $($targets.Count)")
    Write-Blank
    foreach ($target in $targets) {
        $currentText = if ($target.Current) { $target.Current } else { (Get-UiText 'нет параметра' 'parameter missing') }
        Write-Tool 'reading' $target.Path
        Write-Del "maxBytesPerRead=`"$currentText`""
        Write-Add "maxBytesPerRead=`"$newValue`""
    }

    Write-Blank
    if (Test-DryRun (Get-UiText "изменение $($targets.Count) файлов + перезапуск служб Revit Server" "change $($targets.Count) files + restart Revit Server services")) { Wait-Menu; return }
    if (-not (Confirm-Action -Question (Get-UiText "Остановить службы Revit Server и изменить $($targets.Count) файлов?" "Stop Revit Server services and change $($targets.Count) files?") -Danger)) {
        Write-Info (Get-UiText 'Отменено.' 'Cancelled.')
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
                Write-Warn (Get-UiText "параметр не найден: $($target.Path)" "parameter not found: $($target.Path)")
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
    Write-Bullet (Get-UiText "Изменено файлов: $changed, ошибок: $failed" "Files changed: $changed, errors: $failed")
    if ($changed -gt 0) {
        Write-Info (Get-UiText 'Резервные копии лежат рядом с web.config с расширением .bak' 'Backups are next to web.config with the .bak extension')
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
    Write-Bullet (Get-UiText 'Текущие значения RSACCELERATOR' 'Current RSACCELERATOR values')
    Write-Blank
    foreach ($version in $Script:AcceleratorVersions) {
        $value = Get-AcceleratorValue -Version $version
        if ([string]::IsNullOrWhiteSpace($value)) {
            Write-Kv "RSACCELERATOR$version" (Get-UiText 'не задано' 'not set') $Script:C.Faint
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
        $status = if ([string]::IsNullOrWhiteSpace($value)) { (Get-UiText 'не задано' 'not set') } else { $value }
        $options += ("Revit {0}   [{1}]" -f $version, $status)
    }

    $selected = Read-Selection -Options $options -Title (Get-UiText 'Выберите версии Revit' 'Select Revit versions')
    $result = @()
    foreach ($idx in $selected) { $result += [int]$Script:AcceleratorVersions[$idx] }
    return $result
}

function Read-AcceleratorAddress {
    while ($true) {
        $address = Read-Text -Label (Get-UiText 'Адрес акселератора' 'Accelerator address') -Hint (Get-UiText 'Например: 192.168.88.21 или revit-accel.company.local' 'Example: 192.168.88.21 or revit-accel.company.local')
        if (Test-AcceleratorAddress -Address $address) { return $address }
        Write-Fail (Get-UiText 'Адрес пустой или содержит недопустимые символы.' 'Address is empty or contains invalid characters.')
    }
}

function Invoke-ModuleAccelerator {
    while ($true) {
        $items = @(
            [pscustomobject]@{ Key = '1'; Title = (Get-UiText 'Задать акселератор для выбранных версий' 'Set accelerator for selected versions'); Desc = (Get-UiText 'Записывает RSACCELERATOR<год> в переменные пользователя' 'Sets RSACCELERATOR<year> in user environment variables') },
            [pscustomobject]@{ Key = '2'; Title = (Get-UiText 'Задать акселератор для всех версий' 'Set accelerator for all versions'); Desc = "Revit $($Script:AcceleratorVersions[0])-$($Script:AcceleratorVersions[-1])" },
            [pscustomobject]@{ Key = '3'; Title = (Get-UiText 'Отключить акселератор для выбранных версий' 'Disable accelerator for selected versions'); Desc = (Get-UiText 'Удаляет переменные окружения' 'Removes environment variables') },
            [pscustomobject]@{ Key = '4'; Title = (Get-UiText 'Отключить акселератор для всех версий' 'Disable accelerator for all versions'); Desc = (Get-UiText 'Полный сброс' 'Full reset') },
            [pscustomobject]@{ Key = '5'; Title = (Get-UiText 'Показать текущие значения' 'Show current values'); Desc = (Get-UiText 'Таблица по всем годам' 'Table for all years') }
        )

        $choice = Show-Menu -Items $items -Title (Get-UiText 'менеджер Revit Server Accelerator' 'Revit Server Accelerator manager') -BackText (Get-UiText 'Назад' 'Back')
        if ($choice -eq '0') { return }

        Write-Banner
        Write-LogHeader "ACCELERATOR $choice"

        switch ($choice) {
            '1' {
                Write-Prompt (Get-UiText 'акселератор для выбранных версий' 'accelerator for selected versions')
                $versions = Select-RevitVersionForAccelerator
                if ($versions.Count -eq 0) { Write-Blank; Write-Info (Get-UiText 'Ничего не выбрано.' 'Nothing selected.'); Wait-Menu; break }

                $address = Read-AcceleratorAddress
                Write-Blank
                foreach ($version in $versions) { Write-Add "RSACCELERATOR$version = $address" }

                Write-Blank
                if (Test-DryRun (Get-UiText "запись $($versions.Count) переменных окружения" "setting $($versions.Count) environment variables")) { Wait-Menu; break }
                if (-not (Confirm-Action -Question (Get-UiText "Записать адрес для версий: $($versions -join ', ')?" "Set address for versions: $($versions -join ', ')?"))) { Write-Info (Get-UiText 'Отменено.' 'Cancelled.'); Wait-Menu; break }

                foreach ($version in $versions) { Set-AcceleratorValue -Version $version -Address $address }
                Update-EnvironmentBroadcast | Out-Null

                Write-Blank
                Write-Ok (Get-UiText "Готово. Перезапустите Revit, чтобы настройка применилась." "Done. Restart Revit to apply the setting.")
                Wait-Menu
            }

            '2' {
                Write-Prompt (Get-UiText 'акселератор для всех версий' 'accelerator for all versions')
                $address = Read-AcceleratorAddress
                Write-Blank
                foreach ($version in $Script:AcceleratorVersions) { Write-Add "RSACCELERATOR$version = $address" }

                Write-Blank
                if (Test-DryRun (Get-UiText 'запись переменных для всех версий' 'setting variables for all versions')) { Wait-Menu; break }
                if (-not (Confirm-Action -Question (Get-UiText "Задать '$address' для всех версий?" "Set '$address' for all versions?"))) { Write-Info (Get-UiText 'Отменено.' 'Cancelled.'); Wait-Menu; break }

                foreach ($version in $Script:AcceleratorVersions) { Set-AcceleratorValue -Version $version -Address $address }
                Update-EnvironmentBroadcast | Out-Null

                Write-Blank
                Write-Ok (Get-UiText 'Готово. Перезапустите Revit.' 'Done. Restart Revit.')
                Wait-Menu
            }

            '3' {
                Write-Prompt (Get-UiText 'отключение акселератора' 'disable accelerator')
                $versions = Select-RevitVersionForAccelerator
                if ($versions.Count -eq 0) { Write-Blank; Write-Info (Get-UiText 'Ничего не выбрано.' 'Nothing selected.'); Wait-Menu; break }

                Write-Blank
                foreach ($version in $versions) { Write-Del "RSACCELERATOR$version" }

                Write-Blank
                if (Test-DryRun (Get-UiText "удаление $($versions.Count) переменных" "remove $($versions.Count) variables")) { Wait-Menu; break }
                if (-not (Confirm-Action -Question (Get-UiText "Удалить переменные для версий: $($versions -join ', ')?" "Remove variables for versions: $($versions -join ', ')?"))) { Write-Info (Get-UiText 'Отменено.' 'Cancelled.'); Wait-Menu; break }

                foreach ($version in $versions) { Remove-AcceleratorValue -Version $version }
                Update-EnvironmentBroadcast | Out-Null

                Write-Blank
                Write-Ok (Get-UiText 'Готово.' 'Done.')
                Wait-Menu
            }

            '4' {
                Write-Prompt (Get-UiText 'отключение акселератора для всех версий' 'disable accelerator for all versions')
                Write-Blank
                foreach ($version in $Script:AcceleratorVersions) { Write-Del "RSACCELERATOR$version" }

                Write-Blank
                if (Test-DryRun (Get-UiText 'удаление всех переменных RSACCELERATOR' 'remove all RSACCELERATOR variables')) { Wait-Menu; break }
                if (-not (Confirm-Action -Question (Get-UiText 'Удалить RSACCELERATOR для всех версий?' 'Remove RSACCELERATOR for all versions?') -Danger)) { Write-Info (Get-UiText 'Отменено.' 'Cancelled.'); Wait-Menu; break }

                foreach ($version in $Script:AcceleratorVersions) { Remove-AcceleratorValue -Version $version }
                Update-EnvironmentBroadcast | Out-Null

                Write-Blank
                Write-Ok (Get-UiText 'Готово.' 'Done.')
                Wait-Menu
            }

            '5' {
                Write-Prompt (Get-UiText 'текущие значения' 'current values')
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
        $items.Add([pscustomobject]@{ Type = (Get-UiText 'Файлы' 'Files'); Path = $path })
    }
    foreach ($path in @(Resolve-RevitDeepFilePath $Version)) {
        $items.Add([pscustomobject]@{ Type = (Get-UiText 'Кэш/остатки' 'Cache / leftovers'); Path = $path })
    }
    foreach ($path in @(Resolve-RevitRegistryPath $Version)) {
        $items.Add([pscustomobject]@{ Type = (Get-UiText 'Реестр' 'registry'); Path = $path })
    }
    foreach ($path in @(Resolve-RevitDeepRegistryPath $Version)) {
        $items.Add([pscustomobject]@{ Type = (Get-UiText 'Реестр (глубоко)' 'Registry (deep scan)'); Path = $path })
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
            return [pscustomobject]@{ Ok = $false; Message = (Get-UiText "осталось после удаления: $($Item.Path)" "still present after removal: $($Item.Path)") }
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
    return (Get-UiText 'не найдено' 'not found')
}



function Invoke-AdskLicensingUpdate {
    Write-Banner
    Write-Prompt (Get-UiText 'обновление Autodesk Licensing Service' 'update Autodesk Licensing Service')
    Write-LogHeader 'ADSK LICENSING'
    try { Invoke-AutodeskComponentInstall Licensing -Reinstall }
    catch { Write-Fail $_.Exception.Message }
    Wait-Menu
}

function Invoke-RevitCleanup {
    Write-Banner
    Write-Prompt (Get-UiText 'очистка следов Revit' 'clean up Revit remnants')
    Write-LogHeader 'CLEAN REVIT'

    if (-not (Assert-Admin -Reason (Get-UiText 'Удаление файлов в Program Files и веток реестра HKLM требует прав администратора.' 'Deleting Program Files entries and HKLM registry keys requires administrator privileges.'))) { Wait-Menu; return }

    Write-Blank
    Write-Tool 'reading' (Get-UiText 'реестр + Program Files + профили пользователей' 'registry + Program Files + user profiles')
    $versions = @(Get-DetectedRevitVersion)

    $version = $null
    if ($versions.Count -gt 0) {
        $options = @()
        foreach ($v in $versions) { $options += "Revit $v" }
        $options += (Get-UiText 'Ввести версию вручную' 'Enter version manually')

        $selected = Read-Selection -Options $options -Title (Get-UiText 'Версия для очистки (выберите одну)' 'Version to clean (select one)')
        if ($selected.Count -eq 0) { Write-Blank; Write-Info (Get-UiText 'Отменено.' 'Cancelled.'); Wait-Menu; return }

        $idx = $selected[0]
        if ($idx -lt $versions.Count) { $version = $versions[$idx] }
    }

    if (-not $version) {
        $version = Read-Text -Label (Get-UiText 'Версия Revit' 'Revit version') -Hint (Get-UiText 'Четыре цифры, например 2022' 'Four digits, e.g. 2022')
    }

    if ($version -notmatch '^20\d{2}$') {
        Write-Blank
        Write-Fail (Get-UiText 'Неверный формат версии.' 'Invalid version format.')
        Wait-Menu
        return
    }

    Write-Banner
    Write-Prompt (Get-UiText "поиск следов Revit $version" "search for Revit $version remnants")
    Write-Blank

    $plan = Invoke-Step -Text "scan filesystem + registry (Revit $version)" -Action { Get-RevitCleanupPlan $version }
    $plan = @($plan)

    Write-Blank
    if ($plan.Count -eq 0) {
        Write-Ok (Get-UiText "Следы Revit $version не найдены." "No Revit $version remnants found.")
        Wait-Menu
        return
    }

    Write-Bullet (Get-UiText "Найдено объектов: $($plan.Count)" "Entries found: $($plan.Count)")
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

    if (Test-DryRun (Get-UiText "удаление $($plan.Count) объектов (файлы и ветки реестра)" "remove $($plan.Count) entries (files and registry keys)")) { Wait-Menu; return }

    Write-Warn (Get-UiText 'Операция необратима. Рекомендуется закрыть Revit и сделать точку восстановления.' 'This operation cannot be undone. Close Revit and create a restore point first.')
    if (-not (Confirm-Action -Question (Get-UiText "Удалить все $($plan.Count) объектов для Revit $version?" "Delete all $($plan.Count) entries for Revit $version?") -Danger)) {
        Write-Info (Get-UiText 'Отменено.' 'Cancelled.')
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
        Write-Bar -Current $i -Total $total -Text (Get-UiText "удаление $i / $total" "remove $i / $total")
        $result = Remove-CleanupItem -Item $item
        if ($result.Ok) { $removed++; Write-Log "  DELETED $($item.Type) | $($item.Path)" }
        else { $errors++; Write-Log "  ERROR $($result.Message)" }
    }

    Write-Blank
    Write-Bullet (Get-UiText "Удалено: $removed   Ошибок: $errors" "Removed: $removed   Errors: $errors")
    if ($errors -gt 0) {
        Write-Info (Get-UiText "Подробности в логе: $($Script:Ctx.LogPath)" "Details in log: $($Script:Ctx.LogPath)")
        Write-Info (Get-UiText 'Часть объектов может быть занята процессами Revit или защищена системой.' 'Some entries may be in use by Revit or protected by the system.')
    }
    Write-Blank
    Write-Warn (Get-UiText 'Перед новой установкой Revit перезагрузите Windows.' 'Restart Windows before reinstalling Revit.')

    Wait-Menu
}

function Invoke-ModuleClean {
    while ($true) {
        $items = @(
            [pscustomobject]@{ Key = '1'; Title = (Get-UiText 'Поиск и удаление следов Revit' 'Find and remove Revit remnants'); Desc = (Get-UiText 'Файлы, кэш ODIS/UPI2, ветки реестра, записи установщика' 'Files, ODIS/UPI2 cache, registry keys, installer entries') },
            [pscustomobject]@{ Key = '2'; Title = (Get-UiText 'Обновить Autodesk Licensing Service' 'Update Autodesk Licensing Service'); Desc = (Get-UiText 'Скачать официальный установщик или выбрать локальный EXE' 'Download the official installer or select a local EXE') }
        )

        $choice = Show-Menu -Items $items -Title (Get-UiText 'очистка Revit' 'Revit cleanup') -BackText (Get-UiText 'Назад' 'Back')
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
    if ($Bytes -gt 1GB) { return ((Get-UiText "{0:N2} ГБ" "{0:N2} GB") -f ($Bytes / 1GB)) }
    if ($Bytes -gt 1MB) { return ((Get-UiText "{0:N1} МБ" "{0:N1} MB") -f ($Bytes / 1MB)) }
    if ($Bytes -gt 1KB) { return ((Get-UiText "{0:N0} КБ" "{0:N0} KB") -f ($Bytes / 1KB)) }
    return (Get-UiText "$Bytes Б" "$Bytes B")
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
    Write-Prompt (Get-UiText 'backup-папки и журналы Revit' 'Revit backup folders and journals')
    Write-LogHeader 'BACKUPS AND JOURNALS'

    $documents = [Environment]::GetFolderPath('MyDocuments')

    Write-Blank
    Write-Kv (Get-UiText 'Область поиска backup' 'Backup search folder') $documents
    Write-Kv (Get-UiText 'Журналы' 'Journals') (Join-Path $env:LOCALAPPDATA 'Autodesk\Revit')
    Write-Kv (Get-UiText 'Политика журналов' 'Journal retention policy') (Get-UiText 'старше 7 дней, последние 5 всегда сохраняются' 'older than 7 days; the latest 5 are always kept')

    $customRoot = Read-Text -Label (Get-UiText 'Другая папка для поиска backup (Enter = по умолчанию)' 'Custom backup search folder (Enter = default)')
    if (-not [string]::IsNullOrWhiteSpace($customRoot)) {
        if (Test-Path -LiteralPath $customRoot) { $documents = $customRoot }
        else { Write-Fail (Get-UiText 'Путь не найден, используется папка по умолчанию.' 'Path not found; using the default folder.') }
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
    Write-Bullet (Get-UiText 'Результат поиска' 'Search results')
    Write-Blank
    Write-Kv (Get-UiText 'Backup-папок найдено' 'Backup folders found') ([string]$backups.Count)
    Write-Kv (Get-UiText 'Из них с живым .rvt' 'With an existing .rvt') ("$($safeBackups.Count)   $(Format-Size $backupSize)") $Script:C.Green
    Write-Kv (Get-UiText 'Без парного .rvt' 'Without a matching .rvt') ((Get-UiText "$($orphanBackups.Count)   (пропускаются)" "$($orphanBackups.Count)   (skipped)")) $Script:C.Yellow
    Write-Kv (Get-UiText 'Журналов к удалению' 'Journals to delete') ("$($journals.Count)   $(Format-Size $journalSize)")

    if ($safeBackups.Count -gt 0) {
        Write-Blank
        Write-Host ("  " + $Script:C.Cyan + (Get-UiText 'Backup-папки к удалению' 'Backup folders to delete') + $Script:C.Reset)
        foreach ($entry in ($safeBackups | Select-Object -First 40)) {
            Write-Host ("    " + $Script:C.Faint + "$($entry.Path)   [$(Format-Size $entry.Size)]" + $Script:C.Reset)
            Write-Log "     BACKUP $($entry.Path) -> $($entry.Related)"
        }
        if ($safeBackups.Count -gt 40) { Write-Info (Get-UiText "... и ещё $($safeBackups.Count - 40)" "... and $($safeBackups.Count - 40) more") }
    }

    if ($orphanBackups.Count -gt 0) {
        Write-Blank
        Write-Host ("  " + $Script:C.Yellow + (Get-UiText 'Пропущено: не найден парный .rvt' 'Skipped: no matching .rvt found') + $Script:C.Reset)
        foreach ($entry in ($orphanBackups | Select-Object -First 20)) {
            Write-Host ("    " + $Script:C.Faint + $entry.Path + $Script:C.Reset)
        }
        if ($orphanBackups.Count -gt 20) { Write-Info (Get-UiText "... и ещё $($orphanBackups.Count - 20)" "... and $($orphanBackups.Count - 20) more") }
    }

    # Отчёт CSV
    $report = @()
    foreach ($entry in $safeBackups)   { $report += [pscustomobject]@{ Type = 'Backup'; Path = $entry.Path; Related = $entry.Related; Size = $entry.Size; Status = 'Planned' } }
    foreach ($entry in $orphanBackups) { $report += [pscustomobject]@{ Type = 'Backup'; Path = $entry.Path; Related = ''; Size = $entry.Size; Status = 'Skipped (no RVT)' } }
    foreach ($journal in $journals)    { $report += [pscustomobject]@{ Type = 'Journal'; Path = $journal.FullName; Related = ''; Size = $journal.Length; Status = 'Planned' } }

    $reportPath = Join-Path $documents ("Revit_Backup_Report_{0}.csv" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))

    if ($safeBackups.Count -eq 0 -and $journals.Count -eq 0) {
        Write-Blank
        Write-Ok (Get-UiText 'Удалять нечего.' 'Nothing to delete.')
        Wait-Menu
        return
    }

    Write-Blank
    $freed = Format-Size ($backupSize + $journalSize)
    if (Test-DryRun (Get-UiText "удаление $($safeBackups.Count) backup-папок и $($journals.Count) журналов, освободится $freed" "remove $($safeBackups.Count) backup folders and $($journals.Count) journals, free $freed")) {
        try {
            $report | Export-Csv -LiteralPath $reportPath -NoTypeInformation -Encoding UTF8
            Write-Ok (Get-UiText "Отчёт: $reportPath" "Report: $reportPath")
        }
        catch { Write-Fail (Get-UiText "не удалось сохранить отчёт: $($_.Exception.Message)" "could not save report: $($_.Exception.Message)") }
        Wait-Menu
        return
    }

    if (-not (Confirm-Action -Question (Get-UiText "Удалить $($safeBackups.Count) backup-папок и $($journals.Count) журналов (освободится $freed)?" "Delete $($safeBackups.Count) backup folders and $($journals.Count) journals (free $freed)?") -Danger)) {
        Write-Info (Get-UiText 'Отменено. Сохраняю только отчёт.' 'Cancelled. Saving the report only.')
        try {
            $report | Export-Csv -LiteralPath $reportPath -NoTypeInformation -Encoding UTF8
            Write-Ok (Get-UiText "Отчёт: $reportPath" "Report: $reportPath")
        }
        catch { Write-Fail (Get-UiText "не удалось сохранить отчёт: $($_.Exception.Message)" "could not save report: $($_.Exception.Message)") }
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
        Write-Bar -Current $i -Total $total -Text (Get-UiText 'backup-папки' 'backup folders')
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
        Write-Bar -Current $i -Total $total -Text (Get-UiText 'журналы' 'Journals')
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
    Write-Bullet (Get-UiText 'Итог' 'Result')
    Write-Blank
    Write-Kv (Get-UiText 'Удалено backup-папок' 'Backup folders deleted') ((Get-UiText "$deletedBackups из $($safeBackups.Count)" "$deletedBackups of $($safeBackups.Count)")) $Script:C.Green
    Write-Kv (Get-UiText 'Удалено журналов' 'Journals deleted') ((Get-UiText "$deletedJournals из $($journals.Count)" "$deletedJournals of $($journals.Count)")) $Script:C.Green
    if ($failedBackups -gt 0 -or $failedJournals -gt 0) {
        Write-Kv (Get-UiText 'Ошибок' 'Errors') ([string]($failedBackups + $failedJournals)) $Script:C.Red
    }
    Write-Kv (Get-UiText 'Освобождено' 'Space freed') $freed

    try {
        $report | Export-Csv -LiteralPath $reportPath -NoTypeInformation -Encoding UTF8
        Write-Blank
        Write-Ok (Get-UiText "Отчёт: $reportPath" "Report: $reportPath")
    }
    catch { Write-Fail (Get-UiText "не удалось сохранить отчёт: $($_.Exception.Message)" "could not save report: $($_.Exception.Message)") }

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

# Product folders can omit "Autodesk" in their name (including RVT caches).
$NamePattern = 'Autodesk|Revit|pyRevit|^AutoCAD|^Civil 3D|^3ds Max|^Inventor|^Maya|^Navisworks|^Adsk|^RVT\s*20\d{2}'

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
            Write-AutodeskLog (Get-UiText "Пропущен слишком широкий путь ($Source): $n" "Skipped overly broad path ($Source): $n") WARN
            return
        }
        if (-not $AllowMissing -and -not (Test-Path -LiteralPath $n -PathType Container)) { return }
        if (-not $found.ContainsKey($n)) { $found[$n] = $Source }
    }

    # 1. Стандартные каталоги
    @(
        "$PF\Autodesk", "$PF86\Autodesk",
        "$env:SystemDrive\Autodesk",
        "$PF\Common Files\Autodesk", "$PF86\Common Files\Autodesk",
        "$PF\Common Files\Autodesk Shared", "$PF86\Common Files\Autodesk Shared",
        "$PF\Common Files\Macrovision Shared\FLEXnet Publisher",
        "$PF86\Common Files\Macrovision Shared\FLEXnet Publisher",
        "$PD\Autodesk", "$PD\FLEXnet"
    ) | ForEach-Object { & $add $_ (Get-UiText 'стандартный' 'standard') $false }

    # 2. Каталоги верхнего уровня с Autodesk / Revit / pyRevit в имени
    foreach ($root in @($PF, $PF86, $PD)) {
        if (-not $root -or -not (Test-Path -LiteralPath $root)) { continue }
        Get-ChildItem -LiteralPath $root -Directory -Force -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -match $NamePattern } |
            ForEach-Object { & $add $_.FullName (Get-UiText 'поиск по имени' 'name search') $false }
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
                        & $add $_.InstallLocation (Get-UiText 'реестр' 'registry') $false
                    }
                }
        } catch {}
    }

    # 4. Профили ВСЕХ пользователей (а не только того, кто запустил скрипт)
    foreach ($prof in Get-UserProfilePaths) {
        $who = (Get-UiText "профиль $(Split-Path -Leaf $prof)" "profile $(Split-Path -Leaf $prof)")
        @(
            'AppData\Roaming\Autodesk', 'AppData\Local\Autodesk',
            'AppData\Roaming\pyRevit', 'AppData\Roaming\pyRevit-Master', 'AppData\Local\pyRevit',
            'DC'   # Autodesk Desktop Connector
        ) | ForEach-Object { & $add (Join-Path $prof $_) $who $false }

        foreach ($sub in @('AppData\Roaming', 'AppData\Local', 'AppData\LocalLow')) {
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
            Write-AutodeskLog (Get-UiText "Defender в режиме '$($st.AMRunningMode)' - вероятно, установлен сторонний антивирус. Исключения Autodesk нужно добавить и в него." "Defender mode is '$($st.AMRunningMode)' - another antivirus may be installed. Add Autodesk exclusions there as well.") WARN
        }
        if (-not $st.AntivirusEnabled) {
            Write-AutodeskLog (Get-UiText 'Антивирус Defender выключен. Исключения сохранятся и начнут действовать после его включения.' 'Defender antivirus is disabled. Exclusions will take effect when it is enabled.') WARN
        }
    } catch {
        Write-AutodeskLog (Get-UiText "Служба Defender недоступна: $($_.Exception.Message)" "Defender service unavailable: $($_.Exception.Message)") ERROR
        $ok = $false
    }
    try {
        $v = (Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender' -Name DisableLocalAdminMerge -ErrorAction Stop).DisableLocalAdminMerge
        if ($v -eq 1) {
            Write-AutodeskLog (Get-UiText 'Включена политика DisableLocalAdminMerge: локальные исключения игнорируются. Задайте их через GPO/Intune.' 'DisableLocalAdminMerge policy is enabled: local exclusions are ignored. Configure them through GPO/Intune.') WARN
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
            throw (Get-UiText "Не удалось прочитать файл учёта $f : $($_.Exception.Message)" "Could not read ownership file $f : $($_.Exception.Message)")
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
        State = if (-not $exe.Count) {(Get-UiText 'НЕ НАЙДЕН' 'NOT FOUND')} elseif ($enabled -gt 0) {(Get-UiText 'PUBLIC: БЛОК' 'PUBLIC: BLOCK')} else {(Get-UiText 'PUBLIC: НЕТ' 'PUBLIC: NONE')}
    }
}

function Set-ProductInternet {
    param(
        [ValidateSet('AutoCAD','Revit')][string]$Product,
        [bool]$Block
    )
    $exe = @(Get-ProductExecutables $Product)
    if ($Block -and -not $exe.Count) { Write-AutodeskLog (Get-UiText "${Product}: исполняемые файлы не найдены." "${Product}: no executables found.") WARN; return }

    foreach ($path in $exe) { Write-Info "${Product}: $path" }
    if (Test-DryRun (Get-UiText "${Product}: блокировка Public = $Block" "${Product}: block Public = $Block")) { return }
    if (-not (Assert-Admin)) { return }
    if (-not (Confirm-Action -Question (Get-UiText "${Product}: блокировка Public = $Block ?" "${Product}: block Public = $Block ?") -Danger)) { return }
    if ($Block) {
        foreach ($path in $exe) {
            $name = Get-NetRuleName $Product $path
            try {
                Get-NetFirewallRule -DisplayName $name -ErrorAction SilentlyContinue | Where-Object { $_.Group -eq 'Autodesk Defender Exclusions - Network' } | Remove-NetFirewallRule -ErrorAction SilentlyContinue
                # Правило блокирует весь исходящий трафик профиля Public; Private/Domain не затрагивает.
                New-NetFirewallRule -DisplayName $name -Group 'Autodesk Defender Exclusions - Network' `
                    -Direction Outbound -Action Block -Program $path -Profile Public -Enabled True `
                    -Description "Managed by Autodesk_Defender_Exclusions.ps1. Blocks $Product on Public networks only." | Out-Null
                Write-AutodeskLog (Get-UiText "${Product}: Интернет заблокирован (Public): $path" "${Product}: network blocked (Public): $path") OK
            } catch { Write-AutodeskLog (Get-UiText "${Product}: не удалось создать правило для '$path': $($_.Exception.Message)" "${Product}: could not create rule for '$path': $($_.Exception.Message)") ERROR }
        }
    } else {
        try {
            Get-NetFirewallRule -ErrorAction SilentlyContinue |
                Where-Object { $_.Group -eq 'Autodesk Defender Exclusions - Network' -and $_.DisplayName -like "$FirewallPrefix-$Product-*" } |
                Remove-NetFirewallRule -ErrorAction Stop
            Write-AutodeskLog (Get-UiText "${Product}: правила Public этого скрипта удалены." "${Product}: Public rules owned by this script removed.") OK
        } catch { Write-AutodeskLog (Get-UiText "${Product}: ошибка удаления сетевых правил: $($_.Exception.Message)" "${Product}: error removing network rules: $($_.Exception.Message)") ERROR }
    }
}

function Show-NetworkStatus {
    Write-Host (Get-UiText "`n=== СЕТЬ AUTODESK ===" "`n=== AUTODESK NETWORK ===") -ForegroundColor Cyan
    foreach ($product in @('AutoCAD','Revit')) {
        $st = Get-NetworkStatus $product
        $color = if ($st.State -eq (Get-UiText 'PUBLIC: БЛОК' 'PUBLIC: BLOCK')) {'Yellow'} elseif ($st.State -eq (Get-UiText 'PUBLIC: НЕТ' 'PUBLIC: NONE')) {'Green'} else {'DarkGray'}
        Write-Host ((Get-UiText "  {0,-8} : {1,-14} | найдено EXE: {2} | правил: {3}" "  {0,-8} : {1,-14} | EXEs found: {2} | rules: {3}") -f $product,$st.State,$st.Executables.Count,$st.EnabledRules) -ForegroundColor $color
    }
    $allRules = @(Get-NetFirewallRule -Group $AllFirewallGroup -ErrorAction SilentlyContinue)
    Write-Host ((Get-UiText "  Все Autodesk: активных правил {0} (все профили)" "  All Autodesk: active rules {0} (all profiles)") -f @($allRules | Where-Object { $_.Enabled -eq 'True' }).Count) -ForegroundColor Cyan
    Write-Host (Get-UiText '  Отдельные правила AutoCAD / Revit действуют только в профиле Public.' '  Individual AutoCAD / Revit rules apply to the Public profile only.') -ForegroundColor DarkGray
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
    if (Test-DryRun (Get-UiText "все Autodesk: блокировка входящего и исходящего трафика во всех профилях = $Block" "all Autodesk: block inbound and outbound traffic in all profiles = $Block")) { return }
    if (-not (Assert-Admin)) { return }
    if (-not (Confirm-Action -Question (Get-UiText "Все Autodesk: блокировка всех сетевых профилей = $Block ?" "All Autodesk: block all network profiles = $Block ?") -Danger)) { return }
    if (-not $Block) {
        $rules = @(Get-NetFirewallRule -Group $AllFirewallGroup -ErrorAction SilentlyContinue) +
                 @(Get-NetFirewallRule -Group 'Autodesk Defender Exclusions - Network' -ErrorAction SilentlyContinue |
                     Where-Object { $_.DisplayName -like "$FirewallPrefix-*" })
        foreach ($rule in $rules) {
            try { $rule | Remove-NetFirewallRule -ErrorAction Stop; Write-AutodeskLog (Get-UiText "Удалено сетевое правило: $($rule.DisplayName)" "Removed network rule: $($rule.DisplayName)") OK }
            catch { Write-AutodeskLog (Get-UiText "Ошибка удаления правила '$($rule.DisplayName)': $($_.Exception.Message)" "Error removing rule '$($rule.DisplayName)': $($_.Exception.Message)") ERROR }
        }
        if (-not $rules.Count) { Write-AutodeskLog (Get-UiText 'Сетевых правил этого скрипта нет.' 'No network rules owned by this script.') INFO }
        return
    }
    $executables = @(Get-AllAutodeskExecutables)
    if (-not $executables.Count) { Write-AutodeskLog (Get-UiText 'Исполняемые файлы Autodesk не найдены.' 'No Autodesk executables found.') WARN; return }
    Write-Host ((Get-UiText "`nНайдено программ Autodesk: {0}. Создаю правила для всех сетевых профилей..." "`nAutodesk programs found: {0}. Creating rules for all network profiles...") -f $executables.Count) -ForegroundColor Cyan
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
                    if ($existing.Group -ne $AllFirewallGroup) { throw (Get-UiText 'Совпало имя чужого правила; оно не изменено.' 'Name conflicts with another rule; it was not changed.') }
                    $existing | Set-NetFirewallRule -Profile Any -Action Block -Enabled True -ErrorAction Stop
                    continue
                }
                New-NetFirewallRule -Name $name -DisplayName "Autodesk - $([IO.Path]::GetFileName($path))" -Group $AllFirewallGroup `
                    -Direction $dir -Action Block -Program $path -Profile Any -Enabled True `
                    -Description "Managed by Autodesk Control Center. Blocks $dir network traffic on all profiles." -ErrorAction Stop | Out-Null
                $added++
            } catch { Write-AutodeskLog (Get-UiText "Ошибка правила ($dir) для '$path': $($_.Exception.Message)" "Rule error ($dir) for '$path': $($_.Exception.Message)") ERROR; $failed++ }
        }
    }
    $level = if ($failed) { 'WARN' } else { 'OK' }
    Write-AutodeskLog ((Get-UiText "Готово: найдено {0}, новых правил {1}, ошибок {2}. Повторите после установки новых версий Autodesk." "Done: found {0}, new rules {1}, errors {2}. Run again after installing new Autodesk versions.") -f $executables.Count, $added, $failed) $level
}

# Firewall App Blocker (sordum.org) из папки рядом со скриптом. Видит и правила этого скрипта.
function Get-NlmExecutables {
    $base = ${env:ProgramFiles(x86)}
    if (-not $base) { $base = $env:ProgramFiles }
    $folder = Join-Path $base 'Common Files\Autodesk Shared\Network License Manager'
    if (-not (Test-Path -LiteralPath $folder -PathType Container)) { return @() }
    return @(Get-ChildItem -LiteralPath $folder -Filter '*.exe' -File -Recurse -ErrorAction Stop |
        Where-Object { $_.Name -ine 'Revit.exe' } | ForEach-Object { $_.FullName } | Sort-Object -Unique)
}

function Set-NlmInternet {
    param([bool]$Block)
    $group = 'Revit Toolkit - Network License Manager'
    $executables = @()
    if ($Block) {
        $executables = @(Get-NlmExecutables)
        if (-not $executables.Count) { Write-AutodeskLog (Get-UiText 'EXE Network License Manager не найдены.' 'No Network License Manager EXEs found.') WARN; return }
        foreach ($path in $executables) { Write-Info "Network License Manager: $path" }
    }
    if (Test-DryRun (Get-UiText "Network License Manager: блокировка исходящей сети = $Block; правила Revit не изменяются" "Network License Manager: block outbound network = $Block; Revit rules are unchanged")) { return }
    if (-not (Assert-Admin)) { return }
    if (-not (Confirm-Action -Question (Get-UiText "Network License Manager: блокировка исходящей сети = $Block ? Блок включает локальную сеть и может нарушить сетевое лицензирование." "Network License Manager: block outbound network = $Block ? Includes LAN and may disrupt network licensing.") -Danger)) { return }
    if (-not $Block) {
        Get-NetFirewallRule -Group $group -ErrorAction SilentlyContinue | Remove-NetFirewallRule -ErrorAction Stop
        Write-AutodeskLog (Get-UiText 'Удалены правила Network License Manager этого модуля.' 'This module''s Network License Manager rules have been removed.') OK
        return
    }
    foreach ($path in $executables) {
        $name = (Get-AllRuleName $path) -replace '^ADE-ALL-', 'RTK-NLM-'
        try {
            $existing = Get-NetFirewallRule -Name $name -ErrorAction SilentlyContinue
            if ($existing) {
                if ($existing.Group -ne $group) { throw (Get-UiText 'Совпало имя чужого правила; оно не изменено.' 'Name conflicts with another rule; it was not changed.') }
                $existing | Set-NetFirewallRule -Direction Outbound -Profile Any -Action Block -Enabled True -ErrorAction Stop
            } else {
                New-NetFirewallRule -Name $name -DisplayName "Network License Manager - $([IO.Path]::GetFileName($path))" `
                    -Group $group -Direction Outbound -Action Block -Program $path -Profile Any -Enabled True -ErrorAction Stop | Out-Null
            }
            Write-AutodeskLog (Get-UiText "Заблокирована исходящая сеть: $path" "Outbound network blocked: $path") OK
        } catch { Write-AutodeskLog (Get-UiText "Ошибка блокировки '$path': $($_.Exception.Message)" "Error blocking '$path': $($_.Exception.Message)") ERROR }
    }
}

function Start-Fab {
    $exe = if ([Environment]::Is64BitOperatingSystem) { 'Fab_x64.exe' } else { 'Fab.exe' }
    $fab = Get-ChildItem -LiteralPath $ScriptRoot -Directory -Filter 'Fab*' -ErrorAction SilentlyContinue |
        ForEach-Object { Join-Path $_.FullName $exe } |
        Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
    if (-not $fab) {
        if (Test-DryRun (Get-UiText 'скачивание FAB из GitHub Releases и распаковка' 'download FAB from GitHub Releases and extract')) { return }
        if (-not (Assert-Admin)) { return }
        if (-not (Confirm-Action -Question (Get-UiText 'Скачать и открыть FAB из GitHub Releases?' 'Download and open FAB from GitHub Releases?'))) { return }
        $package = Get-ToolkitComponentPackage FAB
        if (-not $package) { return }
        $folder = Join-Path (Split-Path -Parent $package) 'extracted'
        if (-not (Test-Path -LiteralPath $folder)) { Expand-Archive -LiteralPath $package -DestinationPath $folder -ErrorAction Stop }
        $fab = Join-Path $folder ('fab\' + $exe)
        $expected = if ($exe -eq 'Fab_x64.exe') { 'b22d955115f4142198a288550d3592927b1b9460' } else { 'd11b74adf1ad35dd6df0f57004e287859f021a29' }
        if (-not (Test-Path -LiteralPath $fab -PathType Leaf) -or (Get-FileHash -LiteralPath $fab -Algorithm SHA1).Hash -ine $expected) { throw 'FAB executable hash mismatch' }
    }
    if (Test-DryRun (Get-UiText "запуск FAB: $fab" "launch FAB: $fab")) { return }
    if (-not (Assert-Admin)) { return }
    Start-Process -FilePath $fab -WorkingDirectory (Split-Path -Parent $fab)
    Write-AutodeskLog (Get-UiText "Запущен Fab: $fab" "Fab launched: $fab")
}

function Invoke-Install {
    if (-not $Script:Ctx.DryRun -and -not (Assert-Admin)) { return }
    if (-not (Test-DefenderReady)) { return }

    Write-Host (Get-UiText "`nПоиск каталогов Autodesk..." "`nSearching for Autodesk folders...") -ForegroundColor Cyan
    $targets = Get-ExclusionTargets
    Write-Info (Get-UiText 'Исключение папки охватывает все её файлы и подпапки. Network License Manager входит в Autodesk Shared. Сетевые правила не меняются.' 'Folder exclusions cover all files and subfolders. Network License Manager is included in Autodesk Shared. Network rules are unchanged.')
    foreach ($p in ($targets.Keys | Sort-Object)) { Write-Info (Get-UiText "Каталог: $p" "Folder: $p") }
    foreach ($p in $ProcessList) { Write-Info (Get-UiText "Процесс: $p" "Process: $p") }
    if (Test-DryRun (Get-UiText 'добавление недостающих исключений Autodesk' 'adding missing Autodesk exclusions')) { return }
    if (-not (Confirm-Action -Question (Get-UiText 'Добавить исключения Autodesk? Проверка этих каталогов и файлов процессов будет отключена.' 'Add Autodesk exclusions? Scanning these folders and files accessed by these processes will be disabled.') -Danger)) { return }

    $current = Get-CurrentExclusions
    $state   = Read-State

    $added = 0; $exists = 0; $failed = 0

    Write-Host (Get-UiText "`n--- Каталоги ($($targets.Count)) ---" "`n--- Folders ($($targets.Count)) ---") -ForegroundColor Cyan
    foreach ($p in $targets.Keys) {
        if ($current.Paths.Contains($p)) {
            Write-AutodeskLog (Get-UiText "Уже есть: $p" "Already present: $p")
            $exists++
            continue
        }
        try {
            Add-MpPreference -ExclusionPath $p -ErrorAction Stop
            [void]$state.Paths.Add($p); Save-State $state.Paths $state.Processes
            Write-AutodeskLog (Get-UiText "Добавлен каталог [$($targets[$p])]: $p" "Added folder [$($targets[$p])]: $p") OK
            $added++
        } catch {
            Write-AutodeskLog (Get-UiText "Ошибка добавления каталога '$p': $($_.Exception.Message)" "Error adding folder '$p': $($_.Exception.Message)") ERROR
            $failed++
        }
    }

    Write-Host (Get-UiText "`n--- Процессы ($($ProcessList.Count)) ---" "`n--- Processes ($($ProcessList.Count)) ---") -ForegroundColor Cyan
    foreach ($proc in $ProcessList) {
        if ($current.Processes.Contains($proc)) {
            Write-AutodeskLog (Get-UiText "Уже есть: $proc" "Already present: $proc")
            $exists++
            continue
        }
        try {
            Add-MpPreference -ExclusionProcess $proc -ErrorAction Stop
            [void]$state.Processes.Add($proc); Save-State $state.Paths $state.Processes
            Write-AutodeskLog (Get-UiText "Добавлен процесс: $proc" "Added process: $proc") OK
            $added++
        } catch {
            Write-AutodeskLog (Get-UiText "Ошибка добавления процесса '$proc': $($_.Exception.Message)" "Error adding process '$proc': $($_.Exception.Message)") ERROR
            $failed++
        }
    }

    Save-State $state.Paths $state.Processes
    if (Test-Path -LiteralPath $LegacyMarker) {
        Remove-Item -LiteralPath $LegacyMarker -Force -ErrorAction SilentlyContinue
        Write-AutodeskLog (Get-UiText 'Старый файл учёта рядом со скриптом перенесён в ProgramData.' 'Legacy ownership file next to the script migrated to ProgramData.')
    }

    # Контрольная проверка
    $after = Get-CurrentExclusions
    $missing = @($targets.Keys | Where-Object { -not $after.Paths.Contains($_) }) +
               @($ProcessList  | Where-Object { -not $after.Processes.Contains($_) })

    Write-Host ''
    Write-AutodeskLog ((Get-UiText "Итог: добавлено {0}, уже было {1}, ошибок {2}." "Result: added {0}, already present {1}, errors {2}.") -f $added, $exists, $failed) $(if ($failed) { 'WARN' } else { 'OK' })
    if ($missing.Count) {
        Write-AutodeskLog (Get-UiText "После установки не применились: $($missing -join '; ')" "Not applied after installation: $($missing -join '; ')") ERROR
    } else {
        Write-AutodeskLog (Get-UiText 'Проверка пройдена: все исключения Autodesk активны.' 'Verification passed: all Autodesk exclusions are active.') OK
    }
}

function Invoke-Check {
    [void](Test-DefenderReady)
    $targets = Get-ExclusionTargets
    $current = Get-CurrentExclusions
    $state   = Read-State
    $miss = 0

    Write-Host (Get-UiText "`n=== Каталоги Autodesk ===" "`n=== Autodesk folders ===") -ForegroundColor Cyan
    foreach ($p in $targets.Keys) {
        if ($current.Paths.Contains($p)) { Write-Host "  [OK]  $p" -ForegroundColor Green }
        else { Write-Host (Get-UiText "  [НЕТ] $p" "  [MISSING] $p") -ForegroundColor Yellow; $miss++ }
    }

    Write-Host (Get-UiText "`n=== Процессы Autodesk ===" "`n=== Autodesk processes ===") -ForegroundColor Cyan
    foreach ($proc in $ProcessList) {
        if ($current.Processes.Contains($proc)) { Write-Host "  [OK]  $proc" -ForegroundColor Green }
        else { Write-Host (Get-UiText "  [НЕТ] $proc" "  [MISSING] $proc") -ForegroundColor Yellow; $miss++ }
    }

    $otherPaths = @($current.Paths | Where-Object { -not $targets.ContainsKey($_) } | Sort-Object)
    $otherProcs = @($current.Processes | Where-Object { $ProcessList -notcontains $_ } | Sort-Object)
    if ($otherPaths.Count -or $otherProcs.Count) {
        Write-Host (Get-UiText "`n=== Прочие исключения Defender ===" "`n=== Other Defender exclusions ===") -ForegroundColor DarkCyan
        $otherPaths | ForEach-Object { Write-Host "  $_" }
        $otherProcs | ForEach-Object { Write-Host (Get-UiText "  $_ (процесс)" "  $_ (process)") }
    }

    Write-Host ''
    if ($miss) { Write-Host (Get-UiText "Не хватает исключений: $miss. Выполните установку (пункт 1)." "Missing exclusions: $miss. Add them using item 1.") -ForegroundColor Yellow }
    else       { Write-Host (Get-UiText 'Все исключения Autodesk на месте.' 'All Autodesk exclusions are present.') -ForegroundColor Green }
    Write-Host ((Get-UiText "Добавлено этим скриптом: каталогов {0}, процессов {1}. Учёт: {2}" "Owned by this script: folders {0}, processes {1}. Ownership file: {2}") -f $state.Paths.Count, $state.Processes.Count, $StateFile) -ForegroundColor DarkGray
}

function Invoke-Remove {
    if (-not $Script:Ctx.DryRun -and -not (Assert-Admin)) { return }
    $state = Read-State
    if (-not $state.Paths.Count -and -not $state.Processes.Count) {
        Write-AutodeskLog (Get-UiText 'Нет исключений, добавленных этим скриптом. Чужие исключения не трогаю.' 'No exclusions owned by this script. Other exclusions are preserved.') WARN
        return
    }

    foreach ($p in $state.Paths) { Write-Info (Get-UiText "Удалить каталог: $p" "Remove folder: $p") }
    foreach ($p in $state.Processes) { Write-Info (Get-UiText "Удалить процесс: $p" "Remove process: $p") }
    if (Test-DryRun (Get-UiText 'удаление только учтённых исключений Autodesk' 'remove only owned Autodesk exclusions')) { return }
    if (-not (Confirm-Action -Question (Get-UiText 'Удалить учтённые исключения Autodesk?' 'Remove owned Autodesk exclusions?'))) { return }

    $leftPaths = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    $leftProcs = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)

    foreach ($p in @($state.Paths)) {
        try {
            Remove-MpPreference -ExclusionPath $p -ErrorAction Stop
            Write-AutodeskLog (Get-UiText "Удалён каталог: $p" "Removed folder: $p") OK
        } catch {
            Write-AutodeskLog (Get-UiText "Не удалось удалить каталог '$p': $($_.Exception.Message)" "Could not remove folder '$p': $($_.Exception.Message)") ERROR
            [void]$leftPaths.Add($p)
        }
    }
    foreach ($p in @($state.Processes)) {
        try {
            Remove-MpPreference -ExclusionProcess $p -ErrorAction Stop
            Write-AutodeskLog (Get-UiText "Удалён процесс: $p" "Removed process: $p") OK
        } catch {
            Write-AutodeskLog (Get-UiText "Не удалось удалить процесс '$p': $($_.Exception.Message)" "Could not remove process '$p': $($_.Exception.Message)") ERROR
            [void]$leftProcs.Add($p)
        }
    }

    Save-State $leftPaths $leftProcs     # неудалённое остаётся в учёте для повторной попытки
    Remove-Item -LiteralPath $LegacyMarker -Force -ErrorAction SilentlyContinue

    if ($leftPaths.Count -or $leftProcs.Count) {
        Write-AutodeskLog (Get-UiText 'Удалено не всё - повторите удаление позже.' 'Some entries could not be removed; retry later.') WARN
    } else {
        Write-AutodeskLog (Get-UiText 'Удалены все исключения, добавленные этим скриптом.' 'All exclusions added by this script have been removed.') OK
    }
}


function Export-AntivirusExclusionList {
    $targets = Get-ExclusionTargets
    $paths = @($targets.Keys | Sort-Object)
    foreach ($path in $paths) { Write-Info $path }
    Write-Info (Get-UiText 'Список для ручного добавления в сторонний антивирус. Исключения сканирования и исключения обнаружений могут быть разными настройками.' 'List for manual addition to third-party antivirus. Scan exclusions and detection exclusions may be separate settings.')
    if (Test-DryRun (Get-UiText 'экспорт путей Autodesk/Revit в TXT' 'export Autodesk/Revit paths to TXT')) { return }
    $folder = Join-Path $Script:Root 'exports'
    New-Item -ItemType Directory -Path $folder -Force -ErrorAction Stop | Out-Null
    $file = Join-Path $folder ('Antivirus-exclusions-' + [guid]::NewGuid().ToString('N') + '.txt')
    [IO.File]::WriteAllLines($file, [string[]]$paths, (New-Object Text.UTF8Encoding($true)))
    Write-Ok $file
}

function Invoke-AntivirusMenu {
    while ($true) {
        $items = @(
            [pscustomobject]@{ Key='1'; Title=(Get-UiText 'Состояние антивирусов' 'Antivirus status'); Desc=(Get-UiText 'Defender и зарегистрированные сторонние продукты' 'Defender and registered third-party products') },
            [pscustomobject]@{ Key='2'; Title=(Get-UiText 'Временно выключить защиту Defender' 'Temporarily turn off Defender protection'); Desc=(Get-UiText 'Только проверка в реальном времени; Windows может включить её снова' 'Real-time protection only; Windows may enable it again') },
            [pscustomobject]@{ Key='3'; Title=(Get-UiText 'Включить защиту Defender' 'Turn on Defender protection'); Desc=(Get-UiText 'Проверка в реальном времени' 'Real-time protection') },
            [pscustomobject]@{ Key='4'; Title=(Get-UiText 'Исключения для стороннего антивируса' 'Exclusions for third-party antivirus'); Desc=(Get-UiText 'Экспорт путей Autodesk/Revit в TXT; добавление вручную' 'Export Autodesk/Revit paths to TXT; add manually') },
            [pscustomobject]@{ Key='5'; Title=(Get-UiText 'Открыть Безопасность Windows' 'Open Windows Security'); Desc=(Get-UiText 'Настройки защиты и поставщики антивируса' 'Protection settings and antivirus providers') },
            [pscustomobject]@{ Key='6'; Title=(Get-UiText 'Инструкция Kaspersky' 'Kaspersky instructions'); Desc=(Get-UiText 'Официальная справка по исключениям' 'Official exclusion documentation') },
            [pscustomobject]@{ Key='7'; Title=(Get-UiText 'Инструкция ESET' 'ESET instructions'); Desc=(Get-UiText 'Официальная справка по исключениям сканирования и обнаружений' 'Official scan and detection exclusion documentation') }
        )
        $choice = Show-Menu -Items $items -Title (Get-UiText 'Антивирусы и исключения' 'Antivirus and exclusions') -BackText (Get-UiText 'Назад' 'Back')
        if ($choice -eq '0') { return }
        try {
            switch ($choice) {
                '1' { Show-AntivirusStatus }
                '2' { Set-ToolkitDefenderRealtime -Enabled $false }
                '3' { Set-ToolkitDefenderRealtime -Enabled $true }
                '4' { Export-AntivirusExclusionList }
                '5' { if (-not (Test-DryRun 'windowsdefender://threat')) { Start-Process 'windowsdefender://threat' -ErrorAction Stop } }
                '6' { if (-not (Test-DryRun 'Kaspersky help')) { Start-Process 'https://support.kaspersky.com/help/kaspersky/win21.5/en-us/227390.htm' -ErrorAction Stop } }
                '7' { if (-not (Test-DryRun 'ESET help')) { Start-Process 'https://support.eset.com/en/kb2769-exclude-files-or-folders-from-scanning-in-eset-windows-home-products' -ErrorAction Stop } }
            }
        } catch { Write-Fail $_.Exception.Message }
        Wait-Menu
    }
}

    $items = @(
        [pscustomobject]@{ Key='1'; Title=(Get-UiText 'Все Autodesk/Revit: добавить исключения' 'All Autodesk/Revit: add exclusions'); Desc=(Get-UiText 'Все файлы и подпапки найденных каталогов, включая Network License Manager' 'All files and subfolders of discovered folders, including Network License Manager') },
        [pscustomobject]@{ Key='2'; Title=(Get-UiText 'Проверить исключения' 'Check exclusions'); Desc=(Get-UiText 'Найденные, отсутствующие и сторонние исключения' 'Present, missing and other exclusions') },
        [pscustomobject]@{ Key='3'; Title=(Get-UiText 'Удалить учтённые исключения' 'Remove owned exclusions'); Desc=(Get-UiText 'Только добавленные этим скриптом или исходной утилитой' 'Only entries added by this script or the original utility') },
        [pscustomobject]@{ Key='4'; Title=(Get-UiText 'Состояние сети' 'Network status'); Desc=(Get-UiText 'Правила Autodesk в Windows Firewall' 'Autodesk rules in Windows Firewall') },
        [pscustomobject]@{ Key='5'; Title=(Get-UiText 'AutoCAD: блокировать Public' 'AutoCAD: block Public'); Desc=(Get-UiText 'Исходящий трафик' 'Outbound traffic') },
        [pscustomobject]@{ Key='6'; Title=(Get-UiText 'AutoCAD: удалить правила Public' 'AutoCAD: remove Public rules'); Desc=(Get-UiText 'Удаление блокировок утилиты' 'Remove blocks owned by the utility') },
        [pscustomobject]@{ Key='7'; Title=(Get-UiText 'Revit: блокировать Public' 'Revit: block Public'); Desc=(Get-UiText 'Исходящий трафик' 'Outbound traffic') },
        [pscustomobject]@{ Key='8'; Title=(Get-UiText 'Revit: удалить правила Public' 'Revit: remove Public rules'); Desc=(Get-UiText 'Удаление блокировок утилиты' 'Remove blocks owned by the utility') },
        [pscustomobject]@{ Key='a'; Title=(Get-UiText 'Все Autodesk: блокировать сеть' 'All Autodesk: block network'); Desc=(Get-UiText 'Все найденные EXE, оба направления, все профили' 'All discovered EXEs, both directions, all profiles') },
        [pscustomobject]@{ Key='b'; Title=(Get-UiText 'Все Autodesk: удалить блокировки' 'All Autodesk: remove blocks'); Desc=(Get-UiText 'Только правила утилиты' 'Only rules owned by the utility') },
        [pscustomobject]@{ Key='n'; Title=(Get-UiText 'Network License Manager: блокировать сеть' 'Network License Manager: block network'); Desc=(Get-UiText 'Только EXE этой папки; исходящий трафик, все профили' 'Only EXEs in this folder; outbound traffic, all profiles') },
        [pscustomobject]@{ Key='u'; Title=(Get-UiText 'Network License Manager: удалить блокировку' 'Network License Manager: remove block'); Desc=(Get-UiText 'Только правила этого модуля; Revit не изменяется' 'Only this module''s rules; Revit is unchanged') },
        [pscustomobject]@{ Key='f'; Title=(Get-UiText 'Открыть Firewall App Blocker' 'Open Firewall App Blocker'); Desc=(Get-UiText 'Необязательно: папка Fab* рядом со скриптом' 'Optional: Fab* folder next to the script') },
        [pscustomobject]@{ Key='v'; Title=(Get-UiText 'Антивирусы и управление защитой' 'Antivirus and protection controls'); Desc=(Get-UiText 'Состояние, временное отключение Defender, сторонние исключения' 'Status, temporary Defender disable, third-party exclusions') }
    )
    while ($true) {
        $choice = Show-Menu -Items $items -Title (Get-UiText 'Autodesk: Defender и сеть' 'Autodesk: Defender and network') -BackText (Get-UiText 'Назад' 'Back')
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
                'n' { Set-NlmInternet $true }
                'u' { Set-NlmInternet $false }
                'f' { Start-Fab }
                'v' { Invoke-AntivirusMenu }
            }
        } catch { Write-AutodeskLog $_.Exception.Message ERROR }
        Wait-Menu
    }
}

function Show-AntivirusStatus {
    try {
        $status = Get-MpComputerStatus -ErrorAction Stop
        Write-Info "Microsoft Defender: AntivirusEnabled=$($status.AntivirusEnabled); RealTimeProtectionEnabled=$($status.RealTimeProtectionEnabled); IsTamperProtected=$($status.IsTamperProtected); AMRunningMode=$($status.AMRunningMode)"
    } catch { Write-Warn (Get-UiText "Состояние Defender недоступно: $($_.Exception.Message)" "Defender status unavailable: $($_.Exception.Message)") }
    try {
        $products = @(Get-CimInstance -Namespace 'root/SecurityCenter2' -ClassName AntiVirusProduct -ErrorAction Stop)
        foreach ($product in $products) { Write-Info (Get-UiText "Зарегистрирован: $($product.displayName)" "Registered: $($product.displayName)") }
        if (-not $products.Count) { Write-Info (Get-UiText 'Зарегистрированные антивирусы не найдены.' 'No registered antivirus products found.') }
    } catch { Write-Warn (Get-UiText 'Список поставщиков недоступен. На Windows Server SecurityCenter2 может отсутствовать.' 'Provider list unavailable. SecurityCenter2 may be absent on Windows Server.') }
}

function Set-ToolkitDefenderRealtime {
    param([bool]$Enabled)
    $action = if ($Enabled) { Get-UiText 'включить защиту Defender в реальном времени' 'enable Defender real-time protection' } else { Get-UiText 'временно выключить защиту Defender в реальном времени' 'temporarily disable Defender real-time protection' }
    if (Test-DryRun $action) { return }
    if (-not (Assert-Admin)) { return }
    $status = Get-MpComputerStatus -ErrorAction Stop
    if (-not $Enabled -and $status.IsTamperProtected) { throw (Get-UiText 'Защита от изменений включена. Операция остановлена; скрипт не обходит её.' 'Tamper protection is enabled. Operation stopped; the script does not bypass it.') }
    if (-not $status.AntivirusEnabled) { throw (Get-UiText 'Defender не активен как антивирус. Проверьте поставщика защиты и политики Windows.' 'Defender is not active as antivirus. Check the protection provider and Windows policies.') }
    if (-not $Enabled) { Write-Warn (Get-UiText 'Новые файлы временно не будут проверяться в реальном времени. Windows может вернуть защиту; это не постоянное отключение.' 'New files will temporarily not be scanned in real time. Windows may restore protection; this is not a permanent disable.') }
    if (-not (Confirm-Action -Question ($action + '?') -Danger:(-not $Enabled))) { return }
    Set-MpPreference -DisableRealtimeMonitoring (-not $Enabled) -ErrorAction Stop
    $after = Get-MpComputerStatus -ErrorAction Stop
    if ([bool]$after.RealTimeProtectionEnabled -ne $Enabled) { throw (Get-UiText 'Windows не применила изменение. Проверьте защиту от изменений и политики организации.' 'Windows did not apply the change. Check tamper protection and organization policies.') }
    Write-Ok $action
}

# RSN.ini lists Revit Server Hosts, one address per line (not INI sections).
function Get-RsnPath {
    param([ValidateRange(2000, 2099)][int]$Version)
    return Join-Path $env:ProgramData "Autodesk\Revit Server $Version\Config\RSN.ini"
}

function Test-RsnAddress {
    param([string]$Address)
    if ([string]::IsNullOrWhiteSpace($Address) -or $Address.Length -gt 63 -or $Address -ne $Address.Trim()) { return $false }
    $ip = $null
    if ([Net.IPAddress]::TryParse($Address, [ref]$ip)) {
        if ($ip.AddressFamily -eq [Net.Sockets.AddressFamily]::InterNetwork) { return $Address -match '^\d{1,3}(\.\d{1,3}){3}$' }
        return $true
    }
    if ($Address -match '^[\d.]+$') { return $false }
    return $Address -match '^[a-zA-Z0-9](?:[a-zA-Z0-9_-]*[a-zA-Z0-9])?(?:\.[a-zA-Z0-9](?:[a-zA-Z0-9_-]*[a-zA-Z0-9])?)*$'
}

function Get-RsnLines {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return @() }
    return @([IO.File]::ReadAllLines($Path))
}

function Get-RsnEntries {
    param([AllowEmptyCollection()][string[]]$Lines)
    for ($i = 0; $i -lt $Lines.Count; $i++) {
        $address = $Lines[$i].Trim()
        if ($address -and $address -notmatch '^[#;]') {
            [pscustomobject]@{ Index=$i; Address=$address }
        }
    }
}

function Update-RsnLines {
    param(
        [AllowEmptyCollection()][string[]]$Lines,
        [ValidateSet('Add', 'Edit', 'Remove')][string]$Action,
        [string]$Address = '',
        [int]$Index = -1
    )
    if ($Action -ne 'Remove' -and -not (Test-RsnAddress $Address)) {
        throw (Get-UiText 'Недопустимый адрес сервера. Введите имя или IP без URL, порта и пробелов; максимум 63 символа.' 'Invalid server address. Enter a name or IP without URL, port or spaces; maximum 63 characters.')
    }
    if ($Action -ne 'Add' -and ($Index -lt 0 -or $Index -ge $Lines.Count)) { throw 'Invalid RSN line index' }
    $entries = @(Get-RsnEntries $Lines)
    if ($Action -ne 'Remove' -and @($entries | Where-Object { $_.Index -ne $Index -and $_.Address -ieq $Address }).Count) {
        throw (Get-UiText 'Такой сервер уже есть в RSN.ini.' 'This server is already in RSN.ini.')
    }
    if ($Action -eq 'Add') { return @($Lines) + @($Address) }
    for ($i = 0; $i -lt $Lines.Count; $i++) {
        if ($i -ne $Index) { $Lines[$i] }
        elseif ($Action -eq 'Edit') { $Address }
    }
}

function Save-RsnLines {
    param([string]$Path, [AllowEmptyCollection()][string[]]$Lines)
    Write-Info $Path
    foreach ($line in $Lines) { Write-Info "  $line" }
    if (Test-DryRun (Get-UiText 'сохранение RSN.ini с резервной копией существующего файла' 'save RSN.ini with a backup of the existing file')) { return }
    if (-not (Assert-Admin)) { return }
    if (-not (Confirm-Action -Question (Get-UiText 'Сохранить список серверов в RSN.ini?' 'Save the server list to RSN.ini?'))) { return }
    $directory = Split-Path -Parent $Path
    New-Item -ItemType Directory -Path $directory -Force -ErrorAction Stop | Out-Null
    $temp = Join-Path $directory ('RSN-' + [guid]::NewGuid() + '.tmp')
    try {
        # UTF-8 without BOM, CRLF; File.Replace keeps an exact backup and commits atomically.
        [IO.File]::WriteAllLines($temp, [string[]]$Lines, (New-Object Text.UTF8Encoding($false)))
        if (Test-Path -LiteralPath $Path -PathType Leaf) {
            $backup = $Path + '.' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.' + [guid]::NewGuid().ToString('N').Substring(0, 8) + '.bak'
            [IO.File]::Replace($temp, $Path, $backup)
            Write-Ok (Get-UiText "Резервная копия: $backup" "Backup: $backup")
        } else { [IO.File]::Move($temp, $Path) }
        Write-Ok (Get-UiText 'RSN.ini сохранён. Список определяет видимость серверов в Revit, подключение не проверялось.' 'RSN.ini saved. The list controls server visibility in Revit; connectivity was not checked.')
    } finally {
        if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue }
    }
}

function Select-RsnVersion {
    $versions = @(@(Get-DetectedRevitVersion) + @($Script:AcceleratorVersions) |
        Where-Object { $_ -match '^20\d{2}$' } | Sort-Object -Unique -Descending)
    $items = @()
    for ($i = 0; $i -lt $versions.Count; $i++) {
        $path = Get-RsnPath ([int]$versions[$i])
        $status = if (Test-Path -LiteralPath $path -PathType Leaf) { 'RSN.ini' } else { Get-UiText 'создать RSN.ini' 'create RSN.ini' }
        $items += [pscustomobject]@{ Key=[string]($i + 1); Title="Revit $($versions[$i]) / $status"; Desc=$path }
    }
    $items += [pscustomobject]@{ Key='m'; Title=(Get-UiText 'Другая версия' 'Other version'); Desc='2000-2099' }
    $choice = Show-Menu $items -Title (Get-UiText 'Версия для RSN.ini' 'RSN.ini version') -BackText (Get-UiText 'Назад' 'Back')
    if ($choice -eq '0') { return $null }
    if ($choice -eq 'm') {
        $raw = Read-Text -Label (Get-UiText 'Год версии Revit (Enter — отмена)' 'Revit version year (Enter to cancel)')
        if ($raw -match '^20\d{2}$') { return [int]$raw }
        Write-Warn (Get-UiText 'Версия должна содержать четыре цифры: 2000–2099.' 'Version must be four digits: 2000–2099.')
        return $null
    }
    return [int]$versions[[int]$choice - 1]
}

function Select-RsnAddress {
    $known = @()
    $root = Join-Path $env:ProgramData 'Autodesk'
    foreach ($folder in @(Get-ChildItem -LiteralPath $root -Directory -Filter 'Revit Server 20*' -ErrorAction SilentlyContinue)) {
        $file = Join-Path $folder.FullName 'Config\RSN.ini'
        $known += @(Get-RsnEntries @(Get-RsnLines $file) | Where-Object { Test-RsnAddress $_.Address } | ForEach-Object { $_.Address })
    }
    $known = @($known | Sort-Object -Unique)
    if ($known.Count) {
        $items = @([pscustomobject]@{ Key='m'; Title=(Get-UiText 'Ввести новый адрес' 'Enter a new address'); Desc=(Get-UiText 'Имя сервера или IP' 'Server name or IP') })
        for ($i = 0; $i -lt $known.Count; $i++) {
            $items += [pscustomobject]@{ Key=[string]($i + 1); Title=$known[$i]; Desc=(Get-UiText 'Из существующих RSN.ini' 'From existing RSN.ini files') }
        }
        $choice = Show-Menu $items -Title (Get-UiText 'Выберите сервер или добавьте новый' 'Select a server or add a new one') -BackText (Get-UiText 'Отмена' 'Cancel')
        if ($choice -eq '0') { return $null }
        if ($choice -ne 'm') { return $known[[int]$choice - 1] }
    }
    while ($true) {
        $address = Read-Text -Label (Get-UiText 'Адрес сервера (Enter — отмена)' 'Server address (Enter to cancel)') -Hint 'SRV-BIM01 / revit.company.local / 192.168.1.10'
        if (-not $address) { return $null }
        if (Test-RsnAddress $address) { return $address }
        Write-Warn (Get-UiText 'Введите имя или IP без URL и порта; не более 63 символов, имя не начинается с подчёркивания.' 'Enter a name or IP without URL or port; at most 63 characters, name cannot start with an underscore.')
    }
}

function Invoke-ModuleRsn {
    $version = Select-RsnVersion
    if (-not $version) { return }
    while ($true) {
        $path = Get-RsnPath $version
        $items = @(
            [pscustomobject]@{ Key='1'; Title=(Get-UiText 'Создать RSN.ini / добавить сервер' 'Create RSN.ini / add a server'); Desc=(Get-UiText 'Выбор известного сервера или ввод нового; существующие адреса сохраняются' 'Select a known server or enter a new one; existing addresses are preserved') },
            [pscustomobject]@{ Key='2'; Title=(Get-UiText 'Редактировать адрес сервера' 'Edit a server address'); Desc=$path },
            [pscustomobject]@{ Key='3'; Title=(Get-UiText 'Удалить адрес сервера' 'Remove a server address'); Desc=(Get-UiText 'Выбор записи из текущего списка' 'Select an entry from the current list') },
            [pscustomobject]@{ Key='4'; Title=(Get-UiText 'Показать список серверов' 'Show server list'); Desc=$path },
            [pscustomobject]@{ Key='5'; Title=(Get-UiText 'Выбрать другую версию' 'Select another version'); Desc="Revit $version" }
        )
        $choice = Show-Menu $items -Title "RSN.ini / Revit $version" -BackText (Get-UiText 'Назад' 'Back')
        if ($choice -eq '0') { return }
        if ($choice -eq '5') {
            $selected = Select-RsnVersion
            if ($selected) { $version = $selected }
            continue
        }
        try {
            $lines = @(Get-RsnLines $path)
            $entries = @(Get-RsnEntries $lines)
            if ($choice -eq '4') {
                Write-Info $path
                if (-not $entries.Count) { Write-Info (Get-UiText 'Список пуст или файл ещё не создан.' 'The list is empty or the file has not been created yet.') }
                foreach ($entry in $entries) { Write-Kv ([string]($entry.Index + 1)) $entry.Address }
            } elseif ($choice -eq '1') {
                $address = Select-RsnAddress
                if ($address) { Save-RsnLines $path @(Update-RsnLines -Lines $lines -Action Add -Address $address) }
            } else {
                if (-not $entries.Count) { Write-Info (Get-UiText 'Серверов для редактирования или удаления нет.' 'No servers to edit or remove.'); Wait-Menu; continue }
                $servers = @()
                for ($i = 0; $i -lt $entries.Count; $i++) {
                    $servers += [pscustomobject]@{ Key=[string]($i + 1); Title=$entries[$i].Address; Desc=$path }
                }
                $selected = Show-Menu $servers -Title (Get-UiText 'Выберите сервер' 'Select a server') -BackText (Get-UiText 'Отмена' 'Cancel')
                if ($selected -ne '0') {
                    $entry = $entries[[int]$selected - 1]
                    if ($choice -eq '3') { Save-RsnLines $path @(Update-RsnLines -Lines $lines -Action Remove -Index $entry.Index) }
                    else {
                        Write-Info (Get-UiText "Текущий адрес: $($entry.Address)" "Current address: $($entry.Address)")
                        $address = Select-RsnAddress
                        if ($address -and $address -ine $entry.Address) { Save-RsnLines $path @(Update-RsnLines -Lines $lines -Action Edit -Address $address -Index $entry.Index) }
                    }
                }
            }
        } catch { Write-Fail $_.Exception.Message }
        Wait-Menu
    }
}

function Get-LicenseLocalhostCleanup {
    param([string]$Value)
    $parts = @($Value -split '[;,]' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    $keep = @($parts | Where-Object { $_ -notmatch '^(?:\d*@)?(?:localhost|127\.0\.0\.1|\[?::1\]?)$' })
    $changed = $keep.Count -ne $parts.Count
    $updated = if ($changed) { $keep -join ';' } else { $Value }
    [pscustomobject]@{ Changed=$changed; Value=$updated }
}

function Get-LicenseRepairRoot {
    return Join-Path $env:ProgramData 'RevitToolkit\LicenseRepair'
}

function New-LicenseRepairBackup {
    $root = Get-LicenseRepairRoot
    $backup = Join-Path $root ((Get-Date -Format 'yyyyMMdd-HHmmss') + '-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    New-Item -ItemType Directory -Path $backup -Force -ErrorAction Stop | Out-Null
    $values = @()
    foreach ($target in @('User', 'Machine', 'Process')) {
        foreach ($name in @('ADSKFLEX_LICENSE_FILE', 'LM_LICENSE_FILE')) {
            $values += [pscustomobject]@{ Name=$name; Target=$target; Value=[Environment]::GetEnvironmentVariable($name, $target) }
        }
    }
    $values | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $backup 'LicenseEnvironment.json') -Encoding UTF8
    foreach ($key in @('SOFTWARE\FLEXlm License Manager\AdskNLM', 'SOFTWARE\WOW6432Node\FLEXlm License Manager\AdskNLM', 'SYSTEM\CurrentControlSet\Services\AdskNLM')) {
        if (-not (Test-Path -LiteralPath "HKLM:\$key")) { continue }
        $name = $key.Replace('\', '_') + '.reg'
        & reg.exe export "HKLM\$key" (Join-Path $backup $name) /y | Out-Null
        if ($LASTEXITCODE -ne 0) { throw (Get-UiText 'Не удалось сохранить реестр. Очистка остановлена.' 'Registry backup failed. Cleanup stopped.') }
    }
    Write-Ok (Get-UiText "Резервная копия: $backup" "Backup: $backup")
    return $backup
}

function Show-LicenseDiagnostics {
    Write-Kv 'AdskLicensing' (Get-AdskLicensingVersionText)
    foreach ($name in @('AdskLicensingService', 'AdskNLM')) {
        $service = Get-Service -Name $name -ErrorAction SilentlyContinue
        $status = if ($service) { [string]$service.Status } else { Get-UiText 'не найдено' 'not found' }
        Write-Kv $name $status
    }
    foreach ($target in @('User', 'Machine', 'Process')) {
        foreach ($name in @('ADSKFLEX_LICENSE_FILE', 'LM_LICENSE_FILE')) {
            $value = [Environment]::GetEnvironmentVariable($name, $target)
            Write-Kv "$name / $target" $value
        }
    }
    foreach ($folder in @(
        "$env:ProgramFiles\Autodesk Network License Manager",
        "${env:ProgramFiles(x86)}\Autodesk Network License Manager",
        "$env:ProgramFiles\Autodesk\Network License Manager",
        "${env:ProgramFiles(x86)}\Common Files\Autodesk Shared\Network License Manager"
    )) {
        if (Test-Path -LiteralPath $folder -PathType Container) { Write-Kv 'Network License Manager' $folder }
    }
    $root = Join-Path ${env:CommonProgramFiles(x86)} 'Autodesk Shared\AdskLicensing'
    if (Test-Path -LiteralPath $root) {
        foreach ($file in @(Get-ChildItem -LiteralPath $root -Filter 'version.dll' -File -Recurse -ErrorAction Stop)) {
            $signature = Get-AuthenticodeSignature -LiteralPath $file.FullName
            Write-Info "$($file.FullName) / $($signature.Status)"
            Write-Info ((Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash)
        }
    }
    Write-Info (Get-UiText 'Отчёт по DLL диагностический: файлы автоматически не удаляются.' 'DLL report is diagnostic: files are not removed automatically.')
}

function Invoke-LicenseLocalCleanup {
    Write-Warn (Get-UiText 'Будут удалены служба AdskNLM и её ключи, локальные адреса localhost в FLEX-переменных. Легитимный локальный сервер лицензий может перестать работать.' 'This removes the AdskNLM service and its keys, and localhost entries in FLEX variables. A legitimate local license server may stop working.')
    if (Test-DryRun (Get-UiText 'резервная копия, очистка AdskNLM/localhost и карантин временных папок AdskNLM' 'backup, AdskNLM/localhost cleanup and quarantine of AdskNLM temporary folders')) { return }
    if (-not (Assert-Admin)) { return }
    if (-not (Confirm-Action -Question (Get-UiText 'Очистить локальную конфигурацию AdskNLM/localhost?' 'Clean up the local AdskNLM/localhost configuration?') -Danger)) { return }
    $backup = New-LicenseRepairBackup
    $service = Get-Service -Name 'AdskNLM' -ErrorAction SilentlyContinue
    if ($service) {
        if ($service.Status -ne 'Stopped') { Stop-Service -Name 'AdskNLM' -Force -ErrorAction Stop }
        & sc.exe delete AdskNLM | Out-Null
        if ($LASTEXITCODE -ne 0) { throw 'sc.exe delete AdskNLM failed' }
    }
    foreach ($target in @('User', 'Machine', 'Process')) {
        foreach ($name in @('ADSKFLEX_LICENSE_FILE', 'LM_LICENSE_FILE')) {
            $value = [Environment]::GetEnvironmentVariable($name, $target)
            $result = Get-LicenseLocalhostCleanup $value
            if ($result.Changed) {
                $newValue = if ($result.Value) { $result.Value } else { $null }
                [Environment]::SetEnvironmentVariable($name, $newValue, $target)
                Write-Ok "$name / $target"
            }
        }
    }
    foreach ($key in @('HKLM:\SOFTWARE\FLEXlm License Manager\AdskNLM', 'HKLM:\SOFTWARE\WOW6432Node\FLEXlm License Manager\AdskNLM')) {
        if (Test-Path -LiteralPath $key) { Remove-Item -LiteralPath $key -Recurse -Force -ErrorAction Stop }
    }
    $tempRoot = [IO.Path]::GetFullPath($env:TEMP).TrimEnd('\') + '\'
    foreach ($name in @('Adsk-NLM', 'AdskNLM')) {
        $source = [IO.Path]::GetFullPath((Join-Path $tempRoot $name))
        $destination = [IO.Path]::GetFullPath((Join-Path $backup $name))
        if (-not $source.StartsWith($tempRoot, [StringComparison]::OrdinalIgnoreCase) -or -not $destination.StartsWith($backup.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)) { throw 'Unsafe quarantine path' }
        if (Test-Path -LiteralPath $source) { Move-Item -LiteralPath $source -Destination $destination -ErrorAction Stop }
    }
    Update-EnvironmentBroadcast | Out-Null
    Write-Ok (Get-UiText 'Очистка выполнена. Резервная копия сохранена; перезапустите Autodesk-приложения.' 'Cleanup completed. Backup saved; restart Autodesk applications.')
}

function Invoke-LicenseLoginReset {
    if (Test-DryRun (Get-UiText 'резервная копия и сброс кэша входа текущего пользователя' 'backup and reset the current user sign-in cache')) { return }
    if (-not (Assert-Admin)) { return }
    if (-not (Confirm-Action -Question (Get-UiText 'Сбросить вход Autodesk? Закройте приложения. Потребуется войти заново.' 'Reset Autodesk sign-in? Close applications. You will need to sign in again.') -Danger)) { return }
    $backup = New-LicenseRepairBackup
    foreach ($name in @('AdskIdentityManager', 'AdskLicensingAgent', 'AdSSO')) {
        Get-Process -Name $name -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction Stop
    }
    foreach ($relative in @('Autodesk\Web Services\LoginState.xml', 'Autodesk\Identity Services\idservices.db', 'Autodesk\Identity Services\idservices.db-wal', 'Autodesk\Identity Services\idservices.db-shm')) {
        $file = Join-Path $env:LOCALAPPDATA $relative
        if (-not (Test-Path -LiteralPath $file -PathType Leaf)) { continue }
        $destination = Join-Path $backup ([IO.Path]::GetFileName($file))
        Copy-Item -LiteralPath $file -Destination $destination -ErrorAction Stop
        Remove-Item -LiteralPath $file -Force -ErrorAction Stop
        Write-Ok $file
    }
}

function Test-AutodeskDownloadUri {
    param([string]$Url)
    $uri = $null
    return ([Uri]::TryCreate($Url, [UriKind]::Absolute, [ref]$uri) -and $uri.Scheme -eq 'https' -and
        ($uri.Host -eq 'autodesk.com' -or $uri.Host.EndsWith('.autodesk.com', [StringComparison]::OrdinalIgnoreCase)) -and -not $uri.UserInfo)
}

function Get-ToolkitComponentAsset {
    param([ValidateSet('Identity', 'NLM', 'FAB')][string]$Component)
    $assets = @{
        Identity = @{ Name='AdskIdentityManager-1.12.0-Installer.exe'; Sha256='15ed723753078615a3b545b09f6ed39f20eefce08a66b38a4c5f7e2026c17b8b'; Version='1.12.0' }
        NLM = @{ Name='nlm11.19.9.0_ipv4_ipv6_win64.msi'; Sha256='fc54f6e88f569c5c32df7e65a58a04307d39c2852465fa91cc4ce16a3ad43af7'; Version='11.19.9.0' }
        FAB = @{ Name='fab.zip'; Sha256='278baecab6ce9d729425e5cd0aec0294f2ce5803342afc8328e4c7ae69a8dbfd'; Version='1.9' }
    }
    $asset = $assets[$Component]
    return [pscustomobject]@{ Name=$asset.Name; Sha256=$asset.Sha256; Version=$asset.Version; Url=('https://github.com/viendhyra/Revit-Toolkit/releases/download/components-2026-10-05/' + $asset.Name) }
}

function Get-ToolkitComponentPackage {
    param([ValidateSet('Identity', 'NLM', 'FAB')][string]$Component)
    if (Test-DryRun (Get-UiText "скачивание $Component из GitHub Releases и проверка SHA256" "download $Component from GitHub Releases and verify SHA256")) { return $null }
    $asset = Get-ToolkitComponentAsset $Component
    Write-Info "$Component $($asset.Version)"
    $folder = Join-Path $Script:Root ('components\' + $Component + '\' + $asset.Version)
    $path = Join-Path $folder $asset.Name
    if (-not (Test-Path -LiteralPath $path -PathType Leaf) -or (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -ine $asset.Sha256) {
        New-Item -ItemType Directory -Path $folder -Force -ErrorAction Stop | Out-Null
        $partial = Join-Path $folder ([guid]::NewGuid().ToString('N') + [IO.Path]::GetExtension($asset.Name))
        try {
            [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
            Write-Info $asset.Url
            Invoke-WebRequest -Uri $asset.Url -UseBasicParsing -OutFile $partial -ErrorAction Stop | Out-Null
            if ((Get-FileHash -LiteralPath $partial -Algorithm SHA256).Hash -ine $asset.Sha256) { throw 'Component SHA256 mismatch' }
            if ($Component -ne 'FAB') { Assert-AutodeskInstaller $partial }
            Move-Item -LiteralPath $partial -Destination $path -Force -ErrorAction Stop
        } finally {
            if (Test-Path -LiteralPath $partial) { Remove-Item -LiteralPath $partial -Force -ErrorAction Stop }
        }
    }
    if ($Component -ne 'FAB') { Assert-AutodeskInstaller $path }
    return $path
}

function Get-AutodeskComponentPage {
    param([ValidateSet('Licensing', 'Identity', 'NLM')][string]$Component)
    if ($Component -eq 'NLM') { return 'https://www.autodesk.com/support/technical/article/caas/tsarticles/ts/EB0JPJWkEgBXjZRPBONh1.html' }
    if ($Component -eq 'Licensing') { return 'https://www.autodesk.com/support/technical/article/caas/tsarticles/ts/f5IhBc15i0kOwzBb8lcEN.html' }
    return 'https://www.autodesk.com/support/technical/article/caas/tsarticles/ts/7zbgTemIhA3ltRs4eACL0g.html'
}

function Get-AutodeskComponentLinks {
    param([string]$Html, [ValidateSet('Licensing', 'Identity')][string]$Component)
    $decoded = [Net.WebUtility]::HtmlDecode($Html.Replace('\/', '/').Replace('\u002F', '/'))
    $pattern = if ($Component -eq 'Licensing') { '(?i)AdskLicensing[^/]*?(?:win|installer)[^/]*\.(?:zip|exe)$' } else { '(?i)(?:AdskIdentity|IdentityManager)[^/]*\.(?:zip|exe)$' }
    return @([regex]::Matches($decoded, 'https://[^\s"<>\\]+') | ForEach-Object { $_.Value.TrimEnd("'", ')', ',') } |
        Where-Object { (Test-AutodeskDownloadUri $_) -and ([Uri]$_).AbsolutePath -match $pattern } | Sort-Object -Unique)
}

function Assert-AutodeskInstaller {
    param([string]$Path)
    $signature = Get-AuthenticodeSignature -LiteralPath $Path -ErrorAction Stop
    if ($signature.Status -ne 'Valid' -or -not $signature.SignerCertificate -or $signature.SignerCertificate.Subject -notmatch '(?i)(?:^|,\s*)O="?Autodesk(?:,?\s+Inc\.?)?"?(?:,|$)') {
        throw (Get-UiText 'Установщик не имеет действительной подписи Autodesk. Запуск остановлен.' 'Installer has no valid Autodesk signature. Execution stopped.')
    }
}

function Get-AutodeskComponentInstaller {
    param([ValidateSet('Licensing', 'Identity', 'NLM')][string]$Component)
    $page = Get-AutodeskComponentPage $Component
    Write-Info $page
    $choice = Read-Text -Label (Get-UiText 'Источник: 1 — Autodesk, 2 — локальный EXE/MSI, 3 — GitHub Releases, Enter — отмена' 'Source: 1 — Autodesk, 2 — local EXE/MSI, 3 — GitHub Releases, Enter to cancel')
    if ($choice -eq '3') {
        if ($Component -eq 'Licensing') { throw (Get-UiText 'Licensing Service не включён в этот релиз. Выберите Autodesk или локальный EXE.' 'Licensing Service is not included in this release. Select Autodesk or local EXE.') }
        return Get-ToolkitComponentPackage $Component
    }
    if ($choice -eq '2') {
        $path = (Read-Text -Label (Get-UiText 'Путь к официальному установщику EXE/MSI' 'Path to the official EXE/MSI installer')).Trim('"')
        if (-not $path) { return $null }
        $extension = if ($Component -eq 'NLM') { '.msi' } else { '.exe' }
        if (-not (Test-Path -LiteralPath $path -PathType Leaf) -or [IO.Path]::GetExtension($path) -ine $extension) { throw "Installer $extension not found" }
        Assert-AutodeskInstaller $path
        return (Get-Item -LiteralPath $path).FullName
    }
    if ($choice -ne '1') { return $null }
    if ($Component -eq 'NLM') {
        Write-Info (Get-UiText 'Скачайте MSI со страницы Autodesk, затем выберите локальный файл; либо выберите GitHub Releases.' 'Download the MSI from the Autodesk page, then select the local file; or select GitHub Releases.')
        return $null
    }
    if (Test-DryRun (Get-UiText "скачивание $Component с Autodesk, распаковка и проверка подписи" "download $Component from Autodesk, extract and verify signature")) { return $null }
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    $links = @()
    try { $html = (Invoke-WebRequest -Uri $page -UseBasicParsing -ErrorAction Stop).Content; $links = @(Get-AutodeskComponentLinks $html $Component) }
    catch { Write-Warn (Get-UiText 'Страница Autodesk недоступна. Можно указать прямую официальную ссылку.' 'Autodesk page is unavailable. You can provide an official direct link.') }
    if ($links.Count -eq 1) { $url = $links[0] }
    else {
        foreach ($link in $links) { Write-Info $link }
        $url = Read-Text -Label (Get-UiText 'Прямая HTTPS-ссылка Autodesk на Windows EXE/ZIP (Enter — отмена)' 'Direct Autodesk HTTPS link to Windows EXE/ZIP (Enter to cancel)')
        if (-not $url) { return $null }
    }
    if (-not (Test-AutodeskDownloadUri $url) -or ([Uri]$url).AbsolutePath -notmatch '(?i)\.(exe|zip)$') { throw 'Expected official Autodesk HTTPS EXE/ZIP link' }
    $folder = Join-Path $Script:Root ('components\' + $Component + '\' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $folder -Force -ErrorAction Stop | Out-Null
    $package = Join-Path $folder ([IO.Path]::GetFileName(([Uri]$url).AbsolutePath))
    $response = Invoke-WebRequest -Uri $url -UseBasicParsing -OutFile $package -PassThru -ErrorAction Stop
    $finalUri = if ($response.BaseResponse.ResponseUri) { $response.BaseResponse.ResponseUri.AbsoluteUri } elseif ($response.BaseResponse.RequestMessage.RequestUri) { $response.BaseResponse.RequestMessage.RequestUri.AbsoluteUri } else { $url }
    if (-not (Test-AutodeskDownloadUri $finalUri)) { throw 'Download redirected outside Autodesk' }
    if ([IO.Path]::GetExtension($package) -ieq '.zip') {
        Expand-Archive -LiteralPath $package -DestinationPath (Join-Path $folder 'extracted') -ErrorAction Stop
        $name = if ($Component -eq 'Licensing') { 'AdskLicensing*installer*.exe' } else { '*Identity*Manager*.exe' }
        $executables = @(Get-ChildItem -LiteralPath (Join-Path $folder 'extracted') -Filter $name -File -Recurse -ErrorAction Stop)
        if ($executables.Count -ne 1) { throw 'Could not identify a unique component installer in the archive; use local EXE mode' }
        $package = $executables[0].FullName
    }
    Assert-AutodeskInstaller $package
    Write-Ok $package
    return $package
}

function Invoke-AutodeskComponentInstall {
    param([ValidateSet('Licensing', 'Identity', 'NLM')][string]$Component, [switch]$Reinstall)
    if (Test-DryRun (Get-UiText "скачивание/выбор, проверка подписи и установка $Component; переустановка = $Reinstall" "download/select, verify signature and install $Component; reinstall = $Reinstall")) { return }
    if (-not (Assert-Admin)) { return }
    $installer = Get-AutodeskComponentInstaller $Component
    if (-not $installer) { return }
    if (-not (Confirm-Action -Question (Get-UiText "Установить $Component? Закройте Autodesk-приложения; будет открыт официальный установщик." "Install $Component? Close Autodesk applications; the official installer will open."))) { return }
    Assert-AutodeskInstaller $installer
    if ($Reinstall -and $Component -eq 'Licensing') {
        $uninstaller = Join-Path ${env:CommonProgramFiles(x86)} 'Autodesk Shared\AdskLicensing\uninstall.exe'
        if (Test-Path -LiteralPath $uninstaller) {
            Assert-AutodeskInstaller $uninstaller
            $process = Start-Process -FilePath $uninstaller -ArgumentList '--mode unattended' -Wait -PassThru -ErrorAction Stop
            if ($process.ExitCode -notin @(0, 3010)) { throw "Licensing uninstall failed: $($process.ExitCode)" }
        }
    }
    if ($Component -eq 'NLM') {
        $process = Start-Process -FilePath (Join-Path $env:WINDIR 'System32\msiexec.exe') -ArgumentList @('/i', ('"' + $installer + '"'), '/norestart') -Wait -PassThru -ErrorAction Stop
    } else { $process = Start-Process -FilePath $installer -Wait -PassThru -ErrorAction Stop }
    if ($process.ExitCode -notin @(0, 3010, 1641)) { throw "Installer failed: $($process.ExitCode)" }
    Write-Ok (Get-UiText "Установщик завершён: $($process.ExitCode). Проверьте диагностику." "Installer completed: $($process.ExitCode). Check diagnostics.")
    if ($process.ExitCode -in @(3010, 1641)) { Write-Warn (Get-UiText 'Установщик сообщил о необходимости перезагрузки.' 'The installer reported a restart requirement.') }
}

function Invoke-ModuleLicense {
    while ($true) {
        $items = @(
            [pscustomobject]@{ Key='1'; Title=(Get-UiText 'Диагностика лицензирования' 'Licensing diagnostics'); Desc=(Get-UiText 'Службы, FLEX-переменные, подписи и хэши version.dll' 'Services, FLEX variables, version.dll signatures and hashes') },
            [pscustomobject]@{ Key='2'; Title=(Get-UiText 'Очистить AdskNLM / localhost' 'Clean up AdskNLM / localhost'); Desc=(Get-UiText 'С резервной копией; другие адреса лицензий сохраняются' 'With backup; other license addresses are preserved') },
            [pscustomobject]@{ Key='3'; Title=(Get-UiText 'Сбросить вход Autodesk' 'Reset Autodesk sign-in'); Desc=(Get-UiText 'Кэш текущего пользователя с резервной копией' 'Current user cache with backup') },
            [pscustomobject]@{ Key='4'; Title=(Get-UiText 'Скачать / установить Licensing Service' 'Download / install Licensing Service'); Desc=(Get-UiText 'Официальный установщик Autodesk или локальный EXE' 'Official Autodesk installer or local EXE') },
            [pscustomobject]@{ Key='5'; Title=(Get-UiText 'Скачать / установить Identity Manager' 'Download / install Identity Manager'); Desc=(Get-UiText 'Компонент входа для продуктов 2024 и новее' 'Sign-in component for products 2024 and newer') },
            [pscustomobject]@{ Key='6'; Title=(Get-UiText 'Переустановить Licensing Service' 'Reinstall Licensing Service'); Desc=(Get-UiText 'Сначала получить и проверить установщик, затем удалить старую службу' 'Obtain and verify the installer before removing the old service') },
            [pscustomobject]@{ Key='7'; Title=(Get-UiText 'Открыть резервные копии' 'Open backups'); Desc=(Get-LicenseRepairRoot) },
            [pscustomobject]@{ Key='8'; Title='Network License Manager'; Desc=(Get-UiText 'GitHub Releases или официальный MSI; перед обновлением удалите старую версию NLM' 'GitHub Releases or official MSI; remove the old NLM version before upgrading') }
        )
        $choice = Show-Menu $items -Title (Get-UiText 'Восстановление лицензирования Autodesk' 'Autodesk licensing repair') -BackText (Get-UiText 'Назад' 'Back')
        if ($choice -eq '0') { return }
        try {
            switch ($choice) {
                '1' { Show-LicenseDiagnostics }
                '2' { Invoke-LicenseLocalCleanup }
                '3' { Invoke-LicenseLoginReset }
                '4' { Invoke-AutodeskComponentInstall Licensing }
                '5' { Invoke-AutodeskComponentInstall Identity }
                '6' { Invoke-AutodeskComponentInstall Licensing -Reinstall }
                '7' { $root = Get-LicenseRepairRoot; if (Test-Path -LiteralPath $root) { Start-Process explorer.exe -ArgumentList ('"' + $root + '"') } }
                '8' { Invoke-AutodeskComponentInstall NLM }
            }
        } catch { Write-Fail $_.Exception.Message }
        Wait-Menu
    }
}

function Invoke-SettingsMenu {
    while ($true) {
        $dryText = if ($Script:Ctx.DryRun) { (Get-UiText 'включён' 'enabled') } else { (Get-UiText 'выключен' 'disabled') }
        $yesText = if ($Script:Ctx.AssumeYes) { (Get-UiText 'включён' 'enabled') } else { (Get-UiText 'выключен' 'disabled') }

        $items = @(
            [pscustomobject]@{ Key = '1'; Title = (Get-UiText "Сухой прогон: $dryText" "Dry run: $dryText"); Desc = (Get-UiText 'Ничего не удаляется и не изменяется, только показывается план' 'Shows the plan without deleting or changing anything') },
            [pscustomobject]@{ Key = '2'; Title = (Get-UiText "Без подтверждений: $yesText" "No confirmations: $yesText"); Desc = (Get-UiText 'Опасно: операции выполняются сразу' 'Warning: operations run immediately') },
            [pscustomobject]@{ Key = '3'; Title = (Get-UiText 'Открыть папку логов' 'Open log folder'); Desc = $(if ($Script:Ctx.LogPath) { Split-Path $Script:Ctx.LogPath -Parent } else { (Get-UiText 'лог не пишется' 'logging unavailable') }) },
            [pscustomobject]@{ Key = '4'; Title = (Get-UiText 'Язык интерфейса: Русский' 'Interface language: English'); Desc = 'Русский / English' }
        )

        $choice = Show-Menu -Items $items -Title (Get-UiText 'настройки сессии' 'session settings') -BackText (Get-UiText 'Назад' 'Back')
        switch ($choice) {
            '0' { return }
            '1' { $Script:Ctx.DryRun = -not $Script:Ctx.DryRun }
            '2' {
                if (-not $Script:Ctx.AssumeYes) {
                    Write-Banner
                    Write-Blank
                    Write-Warn (Get-UiText 'Режим без подтверждений выполняет удаление сразу, без вопросов.' 'No-confirmation mode deletes immediately without asking.')
                    if (Confirm-Action -Question (Get-UiText 'Точно включить?' 'Enable this mode?') -Danger) { $Script:Ctx.AssumeYes = $true }
                }
                else { $Script:Ctx.AssumeYes = $false }
            }
            '3' {
                if ($Script:Ctx.LogPath) {
                    Start-Process explorer.exe (Split-Path $Script:Ctx.LogPath -Parent)
                }
            }
            '4' { Select-UiLanguage }
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
        'rsn'      { Invoke-ModuleRsn }
        'license'  { Invoke-ModuleLicense }
    }
}

function Invoke-MainMenu {
    while ($true) {
    $items = @(
        [pscustomobject]@{ Key = '1'; Title = (Get-UiText 'Сводка окружения' 'environment overview'); Desc = (Get-UiText 'Revit, Revit Server, службы, акселераторы, IIS' 'Revit, Revit Server, services, accelerators, IIS') },
        [pscustomobject]@{ Key = '2'; Title = (Get-UiText 'IIS для Revit Server' 'IIS for Revit Server'); Desc = (Get-UiText 'Роли Windows Server, ASP.NET 4.8, WCF HTTP/TCP, IIS 6 compat' 'Windows Server roles, ASP.NET 4.8, WCF HTTP/TCP, IIS 6 compatibility') },
        [pscustomobject]@{ Key = '3'; Title = 'maxBytesPerRead'; Desc = (Get-UiText 'web.config Revit Server: 102400 / 4096 / своё значение' 'Revit Server web.config: 102400 / 4096 / custom value') },
        [pscustomobject]@{ Key = '4'; Title = 'Revit Server Accelerator'; Desc = (Get-UiText 'Переменные RSACCELERATOR2018-2026' 'RSACCELERATOR2018-2026 variables') },
        [pscustomobject]@{ Key = '5'; Title = (Get-UiText 'Очистка Revit' 'Revit cleanup'); Desc = (Get-UiText 'Следы установки, реестр, AdskLicensing' 'Installation remnants, registry, AdskLicensing') },
        [pscustomobject]@{ Key = '6'; Title = (Get-UiText 'Backup-папки и журналы' 'Backup folders and journals'); Desc = (Get-UiText 'Поиск *_backup с парным .rvt, старые журналы, CSV-отчёт' 'Find *_backup with a matching .rvt, old journals, CSV report') },
        [pscustomobject]@{ Key = '7'; Title = (Get-UiText 'Autodesk: Defender и сеть' 'Autodesk: Defender and network'); Desc = (Get-UiText 'Исключения, откат, сетевые блокировки, FAB' 'Exclusions, rollback, network blocks, FAB') },
        [pscustomobject]@{ Key = '8'; Title = (Get-UiText 'Серверы Revit / RSN.ini' 'Revit servers / RSN.ini'); Desc = (Get-UiText 'Создание, добавление, редактирование и удаление адресов' 'Create, add, edit and remove server addresses') },
        [pscustomobject]@{ Key = 'l'; Title = (Get-UiText 'Восстановление лицензирования' 'Licensing repair'); Desc = (Get-UiText 'Диагностика, резервные копии, скачивание и установка компонентов' 'Diagnostics, backups, component downloads and installation') },
        [pscustomobject]@{ Key = '9'; Title = (Get-UiText 'Настройки сессии' 'session settings'); Desc = (Get-UiText 'Сухой прогон, подтверждения, логи' 'Dry run, confirmations, logs') }
    )

    $map = @{
        '1' = 'status'; '2' = 'iis'; '3' = 'maxbytes'; '4' = 'accel'; '5' = 'clean'; '6' = 'backups'; '7' = 'autodesk'; '8' = 'rsn'; 'l' = 'license'
    }

        $choice = Show-Menu -Items $items -Title (Get-UiText 'что делаем' 'choose an action') -BackText (Get-UiText 'Выход' 'Exit')

        if ($choice -eq '0') { return }
        if ($choice -eq '9') { Invoke-SettingsMenu; continue }
        if ($map.ContainsKey($choice)) {
            try { Invoke-ModuleByKey -Key $map[$choice] }
            catch {
                Write-Blank
                Write-Fail (Get-UiText "Непредвиденная ошибка: $($_.Exception.Message)" "Unexpected error: $($_.Exception.Message)")
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
Initialize-UiLanguage

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
        Write-Bullet (Get-UiText 'Сессия завершена.' 'Session ended.')
        if ($Script:Ctx.LogPath) { Write-Info (Get-UiText "Лог: $($Script:Ctx.LogPath)" "Log: $($Script:Ctx.LogPath)") }
        Write-Blank
    }
}
catch {
    Write-Blank
    Write-Fail (Get-UiText "Критическая ошибка: $($_.Exception.Message)" "Critical error: $($_.Exception.Message)")
    Write-Log "FATAL $($_.Exception.ToString())"
    exit 1
}
finally {
    Write-Log "$Script:AppName finished"
    Write-Host $Script:C.Reset -NoNewline
}
