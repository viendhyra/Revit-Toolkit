# Revit Toolkit

Единый терминальный хаб для обслуживания Autodesk Revit и Revit Server.
Пять утилит в одном скрипте: общее меню, общий лог, режим сухого прогона.

```
  Revit Toolkit v1.0.0 · SRV-BIM01 · PS 5.1.19041.4648 · admin
  Стрелки + Enter или номер пункта · 0 — назад/выход
  ──────────────────────────────────────────────────────────────

  ▸ что делаем

  ▸ 1  Сводка окружения
       Revit, Revit Server, службы, акселераторы, IIS
    2  IIS для Revit Server
       Роли Windows Server, ASP.NET 4.8, WCF HTTP/TCP, IIS 6 compat
    3  maxBytesPerRead
       web.config Revit Server: 102400 / 4096 / своё значение
    4  Revit Server Accelerator
       Переменные RSACCELERATOR2018-2026
    5  Очистка Revit
       Следы установки, реестр, AdskLicensing
    6  Backup-папки и журналы
       Поиск *_backup с парным .rvt, старые журналы, CSV-отчёт
    9  Настройки сессии

    0  Выход
```

---

## Запуск прямо из репозитория

### Однострочный запуск (рекомендуется)

Откройте **PowerShell от имени администратора** и выполните:

```powershell
[Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12;$F="$env:TEMP\RevitToolkit.ps1";iwr "https://raw.githubusercontent.com/viendhyra/Revit-Toolkit/main/RevitToolkit.ps1" -OutFile $F;powershell -ExecutionPolicy Bypass -File $F
```

### То же самое по шагам

```powershell
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$Script = "$env:TEMP\RevitToolkit.ps1"

Invoke-WebRequest `
    -Uri "https://raw.githubusercontent.com/viendhyra/Revit-Toolkit/main/RevitToolkit.ps1" `
    -OutFile $Script

Unblock-File $Script

powershell.exe -ExecutionPolicy Bypass -File $Script
```

### Сухой прогон из репозитория

Ничего не удаляется и не изменяется — показывается только план:

```powershell
$F="$env:TEMP\RevitToolkit.ps1";iwr "https://raw.githubusercontent.com/viendhyra/Revit-Toolkit/main/RevitToolkit.ps1" -OutFile $F;powershell -ExecutionPolicy Bypass -File $F -DryRun
```

### Конкретный модуль без меню

```powershell
$F="$env:TEMP\RevitToolkit.ps1";iwr "https://raw.githubusercontent.com/viendhyra/Revit-Toolkit/main/RevitToolkit.ps1" -OutFile $F;powershell -ExecutionPolicy Bypass -File $F -Module backups -DryRun
```

### Запуск с автоматическим повышением прав

Если PowerShell открыт без прав администратора:

```powershell
$F="$env:TEMP\RevitToolkit.ps1";iwr "https://raw.githubusercontent.com/viendhyra/Revit-Toolkit/main/RevitToolkit.ps1" -OutFile $F;Start-Process powershell -Verb RunAs -ArgumentList "-NoExit","-ExecutionPolicy","Bypass","-File","`"$F`""
```

### Клонирование репозитория

```powershell
git clone https://github.com/viendhyra/Revit-Toolkit.git
cd Revit-Toolkit
powershell.exe -ExecutionPolicy Bypass -File .\RevitToolkit.ps1
```

> **Почему не `irm ... | iex`**
> Скрипт начинается с `#Requires -Version 5.1` и принимает параметры через `param()`.
> При `Invoke-Expression` директива `#Requires` не поддерживается, а параметры (`-DryRun`, `-Module`)
> передать невозможно. Поэтому используется скачивание во временный файл и запуск через `-File`.

---

## Параметры

| Параметр | Назначение |
|---|---|
| `-Module <ключ>` | Запуск одного модуля без главного меню |
| `-DryRun` | Сухой прогон: поиск и план выводятся, изменения не выполняются |
| `-Yes` | Без подтверждений (автоматизация, использовать осознанно) |
| `-NoColor` | Отключить ANSI-цвета |
| `-Ascii` | ASCII вместо псевдографики (старые консоли, шрифты без нужных глифов) |

Ключи модулей: `status`, `iis`, `maxbytes`, `accel`, `clean`, `backups`.

```powershell
.\RevitToolkit.ps1 -Module status
.\RevitToolkit.ps1 -Module maxbytes
.\RevitToolkit.ps1 -Module clean -DryRun
```

---

## Модули

### 1. Сводка окружения

Версии Revit из реестра и файловой системы, установки Revit Server с текущими значениями
`maxBytesPerRead`, статус служб Revit Server, заданные переменные `RSACCELERATOR`,
недостающие роли IIS. Права администратора не требуются.

### 2. IIS для Revit Server

Включает роли и компоненты Windows Server, необходимые Revit Server:
Web Server (IIS), ASP.NET 4.8, WCF HTTP/TCP Activation, ASP, CGI, Server Side Includes,
IIS 6 Management Compatibility, Metabase, WMI.

Показывает состояние «до» и «после», перезапускает IIS, предлагает перезагрузку
(не выполняет её автоматически). Требует Windows Server и права администратора.

### 3. maxBytesPerRead

Находит все установки Revit Server, показывает текущее значение в каждом `web.config`,
позволяет выбрать версии и задать 102400, вернуть стандартные 4096 или ввести своё значение.

Перед записью создаётся `.bak`. Службы останавливаются и поднимаются обратно —
только те, что были запущены до операции.

### 4. Revit Server Accelerator

Управление пользовательскими переменными `RSACCELERATOR2018` … `RSACCELERATOR2026`:
задать адрес для выбранных версий или для всех, отключить, посмотреть текущие значения.
После изменения рассылается `WM_SETTINGCHANGE`, чтобы новые процессы увидели переменные
без перелогина. Revit нужно перезапустить.

### 5. Очистка Revit

Поиск и удаление следов установки конкретной версии Revit: папки в Program Files,
ProgramData и профилях пользователей, кэш ODIS/UPI2, ветки реестра Autodesk,
записи установщика Windows. Показывает полный план перед удалением.

Отдельный пункт — переустановка Autodesk Licensing Service
(требуется файл `AdskLicensing-installer *.exe` рядом со скриптом).

### 6. Backup-папки и журналы

Ищет папки `*_backup` и проверяет наличие парного `.rvt` — папки без модели пропускаются.
Журналы отбираются по возрасту: старше 7 дней, последние 5 всегда сохраняются,
чтобы не удалить журнал открытой сессии Revit.

Сначала выводится отчёт с подсчётом освобождаемого места, удаление — только после
подтверждения. CSV-отчёт сохраняется в папку «Документы».

---

## Требования

- Windows 10 / 11 или Windows Server 2019 / 2022
- PowerShell 5.1 или новее
- Права администратора для модулей IIS, maxBytesPerRead, очистки Revit и AdskLicensing

---

## Логи и артефакты

| Что | Где |
|---|---|
| Лог сессии | `%ProgramData%\RevitToolkit\logs` (или `%LOCALAPPDATA%\RevitToolkit\logs`, или `logs` рядом со скриптом) |
| CSV-отчёт по backup | Папка «Документы» |
| Резервные копии `web.config` | Рядом с оригиналом, расширение `.bak` |

---

## Безопасность

Модули очистки удаляют файлы и ветки реестра без возможности отката.
Перед первым запуском на рабочей машине используйте `-DryRun`.

Перед очисткой Revit закройте все запущенные экземпляры Revit и сделайте точку восстановления.

---

## Кодировка

Файл хранится в **UTF-8 с BOM**. Без BOM PowerShell 5.1 ломает кириллицу.
При редактировании и коммите BOM нужно сохранять.

---

## Исходные репозитории

Хаб объединяет пять утилит:

| Модуль | Исходный репозиторий |
|---|---|
| IIS для Revit Server | [Install_RevitServer_IIS](https://github.com/Viend1211/Install_RevitServer_IIS) |
| maxBytesPerRead | [RevitServer-MaxBytesPerRead-Fix](https://github.com/Viend1211/RevitServer-MaxBytesPerRead-Fix) |
| Accelerator | [Revit_RS_Accelerator_Manager](https://github.com/Viend1211/Revit_RS_Accelerator_Manager) |
| Очистка Revit | [Clean-Revit](https://github.com/Viend1211/Clean-Revit) |
| Backup и журналы | [find_revit_backups_and_journals](https://github.com/Viend1211/find_revit_backups_and_journals) |
