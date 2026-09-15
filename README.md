# Revit Toolkit

Единый терминальный хаб для обслуживания Autodesk Revit и Revit Server.
Объединяет пять отдельных скриптов в один файл с общим UI, логом и режимом сухого прогона.

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

## Запуск

```powershell
powershell.exe -ExecutionPolicy Bypass -File .\RevitToolkit.ps1
```

Сухой прогон — ничего не меняется, только показывается план:

```powershell
powershell.exe -ExecutionPolicy Bypass -File .\RevitToolkit.ps1 -DryRun
```

Прямой запуск модуля без меню:

```powershell
.\RevitToolkit.ps1 -Module backups -DryRun
.\RevitToolkit.ps1 -Module maxbytes
.\RevitToolkit.ps1 -Module status
```

Ключи: `status`, `iis`, `maxbytes`, `accel`, `clean`, `backups`.

## Параметры

| Параметр | Назначение |
|---|---|
| `-Module <ключ>` | Запуск одного модуля, без главного меню |
| `-DryRun` | Сухой прогон: поиск и план выводятся, изменения не выполняются |
| `-Yes` | Без подтверждений (автоматизация, использовать осознанно) |
| `-NoColor` | Отключить ANSI-цвета |
| `-Ascii` | ASCII вместо псевдографики (старые консоли, шрифты без глифов) |

## Что вошло в хаб

| Модуль | Исходный репозиторий | Что изменилось при объединении |
|---|---|---|
| IIS для Revit Server | `Install_RevitServer_IIS` | Перезагрузка стала подтверждаемой, а не автоматической; проверка типа ОС; вывод состояния «до/после» |
| maxBytesPerRead | `RevitServer-MaxBytesPerRead-Fix` | Замена по regex вместо точного совпадения строки (работает при любом текущем значении), произвольное значение, `.bak` перед записью, возврат служб только в исходное состояние |
| Accelerator | `Revit_RS_Accelerator_Manager` | Множественный выбор версий, broadcast `WM_SETTINGCHANGE` сохранён |
| Очистка Revit | `Clean-Revit` | WinForms GUI переписан в терминальный режим; та же логика поиска файлов, реестра и записей установщика; прогресс-бар |
| Backup и журналы | `find_revit_backups_and_journals` | Сначала отчёт, удаление только после подтверждения; журналы фильтруются по возрасту (старше 7 дней, последние 5 сохраняются); подсчёт освобождаемого места |

## Требования

- Windows 10 / 11 или Windows Server 2019 / 2022
- PowerShell 5.1 или новее
- Права администратора для модулей IIS, maxBytesPerRead, очистки Revit и AdskLicensing

## Логи

Лог сессии пишется в первый доступный каталог:

```
%ProgramData%\RevitToolkit\logs
%LOCALAPPDATA%\RevitToolkit\logs
<папка скрипта>\logs
```

Отчёт модуля backup — CSV в папке «Документы».
Резервные копии `web.config` — рядом с оригиналом, с расширением `.bak`.

## Кодировка

Файл хранится в **UTF-8 с BOM**. Без BOM PowerShell 5.1 ломает кириллицу.
При редактировании и коммите BOM нужно сохранять.

## Безопасность

Модули очистки удаляют файлы и ветки реестра без возможности отката.
Перед первым запуском на рабочей машине используйте `-DryRun`.
