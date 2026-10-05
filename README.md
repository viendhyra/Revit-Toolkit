# Revit Toolkit

Единый терминальный хаб для обслуживания Autodesk Revit и Revit Server.
Объединяет утилиты обслуживания, настройки Defender и сетевые правила Autodesk в один файл с общим UI, логом и режимом сухого прогона.

```
  Revit Toolkit v1.1.0 · SRV-BIM01 · PS 5.1.19041.4648 · admin
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
    7  Autodesk: Defender и сеть
       Исключения, откат, сетевые блокировки, Network License Manager
    8  Серверы Revit / RSN.ini
       Создание файла, добавление, редактирование и удаление серверов
    l  Восстановление лицензирования
       Диагностика, резервные копии, скачивание и установка компонентов
    9  Настройки сессии

    0  Выход
```

## Запуск

### Прямо из GitHub

Откройте **Windows Terminal / PowerShell от имени администратора** и вставьте команду целиком. Git и клонирование репозитория не нужны. Команда скачивает актуальный скрипт из ветки `main` в `%LOCALAPPDATA%\RevitToolkit` и открывает меню:

```powershell
& { $ErrorActionPreference = 'Stop'; [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12; $toolkitDir = Join-Path $env:LOCALAPPDATA 'RevitToolkit'; New-Item -ItemType Directory -Path $toolkitDir -Force | Out-Null; $toolkitScript = Join-Path $toolkitDir 'RevitToolkit.ps1'; Invoke-WebRequest -UseBasicParsing -Uri 'https://raw.githubusercontent.com/viendhyra/Revit-Toolkit/main/RevitToolkit.ps1' -OutFile $toolkitScript -ErrorAction Stop; powershell.exe -NoProfile -ExecutionPolicy Bypass -File $toolkitScript }
```

Чтобы первый запуск был сухим прогоном, добавьте `-DryRun` после `-File $toolkitScript` в конце команды. Подтверждения изменений остаются включены; запуск открывает меню и сам настройки не применяет. При ошибке скачивания запуск прерывается.

Повторный запуск уже скачанной версии без интернета:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$env:LOCALAPPDATA\RevitToolkit\RevitToolkit.ps1"
```

Запуск скачанного модуля Autodesk с сухим прогоном:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$env:LOCALAPPDATA\RevitToolkit\RevitToolkit.ps1" -Module autodesk -DryRun
```

Для обновления снова выполните первую команду. `ExtraPaths.txt` и необязательную папку `Fab*` размещайте в `%LOCALAPPDATA%\RevitToolkit` рядом со скачанным скриптом.

### Из локальной папки

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

Ключи: `status`, `iis`, `maxbytes`, `accel`, `clean`, `backups`, `autodesk`, `rsn`, `license`.

## Восстановление лицензирования Autodesk

Пункт **l** (латинская L) или `-Module license`: функционал Autodesk License Repair с раздельными действиями и общим интерфейсом RU/EN.

- Диагностика служб `AdskLicensingService` / `AdskNLM`, FLEX-переменных, каталогов Network License Manager, подписей и SHA256 файлов `version.dll` внутри AdskLicensing. DLL автоматически не удаляются.
- Очистка службы `AdskNLM`, её ключей FLEXlm и записей `localhost`, `127.0.0.1`, `::1` в `ADSKFLEX_LICENSE_FILE` / `LM_LICENSE_FILE` (User/Machine/Process). Другие адреса и пути лицензий сохраняются. Это отдельное подтверждаемое действие: оно может отключить легитимный локальный сервер лицензий.
- Сброс кэша входа только текущего пользователя: `LoginState.xml`, `idservices.db` и связанные WAL/SHM-файлы. Перед удалением — копия. После сброса потребуется войти заново.
- Скачивание и установка официального **Autodesk Desktop Licensing Service** и **Autodesk Identity Manager**; отдельный режим переустановки Licensing Service. Обновление из модуля «Очистка Revit» использует тот же механизм.

Скачивание ищет Windows EXE/ZIP на [странице Licensing Service](https://www.autodesk.com/support/technical/article/caas/tsarticles/ts/f5IhBc15i0kOwzBb8lcEN.html) или [странице Identity Manager](https://www.autodesk.com/support/technical/article/caas/tsarticles/ts/7zbgTemIhA3ltRs4eACL0g.html). Если страница недоступна, ссылка не найдена или вариантов несколько, можно вставить прямую официальную HTTPS-ссылку либо выбрать локальный EXE. Поддерживаются только домены Autodesk; перед запуском проверяется действительность Authenticode-подписи и издатель Autodesk. Пакеты сохраняются в `components` рядом со скриптом. Установщик открывается в обычном режиме; код завершения проверяется. Перед переустановкой старого Licensing Service новый установщик уже должен быть получен и проверен.

Резервные копии: `%ProgramData%\RevitToolkit\LicenseRepair\<дата>-<идентификатор>`. Сохраняются FLEX-переменные в JSON и существующие ключи AdskNLM в `.reg`; временные папки AdskNLM переносятся в резервную папку. Автоматического полного отката нет: резервные файлы предназначены для ручного восстановления. Ошибка создания резервной копии останавливает очистку.

Для изменений нужны права администратора и подтверждение. `-DryRun` не скачивает, не устанавливает и не создаёт резервных копий — только показывает план. Закройте приложения Autodesk перед восстановлением и установкой. Скрипт не отключает сетевые блокировки автоматически; ранее созданные правила могут мешать лицензированию и входу.

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\RevitToolkit.ps1 -Module license -DryRun
```

Проверка без изменения ПК: `powershell.exe -NoProfile -File .\Test-LicenseRepair.ps1`.

## Серверы Revit / RSN.ini

Пункт **8** или `-Module rsn` открывает менеджер списка Revit Server Hosts. Выберите версию Revit, затем действие:

- **Создать RSN.ini / добавить сервер** — выбрать адрес из существующих RSN.ini других версий или ввести новое имя/IP. Если файла нет, папка и файл создаются сразу с выбранным адресом. Если файл существует, адрес добавляется к текущему списку.
- **Редактировать / удалить** — выбрать конкретную запись из списка. Остальные строки, комментарии и пустые строки сохраняются.
- **Показать список / выбрать другую версию** — просмотр конфигурации и переход между версиями; можно ввести год вручную.

Файл: `%ProgramData%\Autodesk\Revit Server <год>\Config\RSN.ini`. Каждый сервер записывается отдельной строкой, без секций INI, URL и порта. Дубликаты проверяются без учёта регистра. Имена не начинаются с подчёркивания и не превышают 63 символа. [Формат и расположение по документации Autodesk](https://help.autodesk.com/cloudhelp/2026/RUS/Revit-Installation/files/GUID-00163A5A-1379-4743-87B7-DBBBBF00FC93.htm).

Перед заменой существующего файла создаётся точная резервная копия `RSN.ini.<дата>.<идентификатор>.bak` в той же папке. Запись требует администратора и подтверждения; `-DryRun` показывает будущий файл без записи и создания папок. Удаление последнего адреса оставляет пустой список. Изменение RSN.ini определяет видимость хостов, доступность сервера по сети не проверяется.

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\RevitToolkit.ps1 -Module rsn -DryRun -Language ru
```

Проверка на временных файлах: `powershell.exe -NoProfile -File .\Test-Rsn.ps1`.

## Autodesk: Defender и сеть

Пункт 7 главного меню или `-Module autodesk` открывает модуль из Autodesk Control Center:

- **1 — Все Autodesk/Revit: добавить исключения**: стандартные каталоги, установки из реестра и данные всех пользователей. Включены `Autodesk Shared` с `Network License Manager`, `Common Files\Autodesk`, FLEXnet, папка распакованных установщиков `%SystemDrive%\Autodesk`, кэши `RVT 20xx`, pyRevit и Desktop Connector. Дополнительно распознаются каталоги AutoCAD, Civil 3D, 3ds Max, Inventor, Maya, Navisworks и Adsk в Program Files, ProgramData и AppData (Roaming/Local/LocalLow). Исключение папки распространяется на все вложенные файлы и подпапки: отдельные исключения каждого файла не создаются. Сетевые правила при добавлении исключений не меняются.
- `ExtraPaths.txt` рядом со скриптом: дополнительные абсолютные пути, по одному на строку; строки с `#` пропускаются. Корни дисков и широкие системные каталоги отклоняются.
- Удаление только учтённых исключений. Учёт совместим с исходной утилитой: `%ProgramData%\AutodeskDefenderExclusions\managed.json`.
- Блокировка исходящего трафика AutoCAD/Revit в профиле Public; блокировка всех найденных Autodesk EXE в обоих направлениях во всех сетевых профилях; удаление правил утилиты.
- Запуск необязательного Firewall App Blocker: положите папку `Fab*` с `Fab_x64.exe` / `Fab.exe` рядом со скриптом.
- `n`: блокировать исходящие соединения EXE в `C:\Program Files (x86)\Common Files\Autodesk Shared\Network License Manager` и подпапках (путь учитывает расположение Program Files). `u`: удалить только эти правила. `Revit.exe` исключён из поиска; правила Revit не меняются. Блок действует во всех профилях, включая локальную сеть, и может нарушить сетевое лицензирование. Ранее созданные блокировки Revit остаются: при необходимости удалите их отдельным пунктом или через FAB.

Изменения требуют администратора и подтверждения (`-Yes` пропускает вопросы). `-DryRun` показывает план без изменения исключений, правил и файла учёта. Исключения снижают антивирусную проверку выбранных каталогов и файлов, открываемых указанными процессами; блокировка сети может нарушить вход, лицензирование и облачные функции Autodesk.

Проверка без изменения настроек Windows: `powershell.exe -NoProfile -File .\Test-Autodesk.ps1`.

## Параметры

### Антивирусы / Antivirus

Меню **7 — Autodesk: Defender и сеть → v — Антивирусы**:

- Состояние Defender и названия антивирусов, зарегистрированных в Windows Security Center. На Windows Server список может быть недоступен.
- Временное отключение и включение проверки Defender в реальном времени через `Set-MpPreference`, с подтверждением и проверкой результата. При включённой защите от изменений отключение останавливается. Политики организации могут запретить операцию. Постоянное отключение не реализовано: Windows может автоматически вернуть защиту.
- Экспорт найденных каталогов Autodesk/Revit в TXT в папку `exports`. Добавьте пути в исключения стороннего антивируса вручную. TXT не является форматом импорта Kaspersky/ESET; исключения сканирования и обнаружений настраиваются отдельно, где это предусмотрено продуктом.
- Открытие «Безопасность Windows» и официальных инструкций Kaspersky/ESET.

English: **7 — Autodesk: Defender and network → v — Antivirus** provides Defender status, registered antivirus names, temporary real-time protection disable/enable, and a TXT list of Autodesk/Revit paths for manual third-party exclusions. It does not permanently disable Defender or bypass tamper protection. Third-party exclusions are not automatically applied. Scan and detection exclusions may require separate product settings.

Microsoft documents [real-time protection and exclusions](https://support.microsoft.com/en-us/windows/security/threat-malware-protection/virus-and-threat-protection-in-the-windows-security-app). See also [Kaspersky exclusions](https://support.kaspersky.com/help/kaspersky/win21.5/en-us/227390.htm) and [ESET scan/detection exclusions](https://support.eset.com/en/kb2769-exclude-files-or-folders-from-scanning-in-eset-windows-home-products).

Offline check: `powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Test-Antivirus.ps1`.

### Компоненты из GitHub Releases / Components from GitHub Releases

В модуле лицензирования: **5 — Identity Manager** или **8 — Network License Manager**, затем **3 — GitHub Releases**. Identity Manager — **1.21.0**, сборка **1.21.0.9**, официальный UCT-установщик Autodesk. NLM — **11.19.9.0**. Перед обновлением NLM удалите старую версию согласно инструкции Autodesk.

FAB **1.9** автоматически предлагается скачать при запуске FAB, если локальная папка отсутствует. FAB портативный: архив распаковывается и открывается без отдельного установщика.

Пакеты берутся из релиза `components-2026-10-05` репозитория `viendhyra/Revit-Toolkit`. Скрипт проверяет закреплённый SHA256, для Identity/NLM также действительную подпись Autodesk. Кэш — `<папка скрипта>\components`; повреждённый кэш скачивается заново. `-DryRun` ничего не скачивает и не устанавливает. Установка открывает официальный мастер; его результат проверяется.

Все три пакета опубликованы в [GitHub Releases](https://github.com/viendhyra/Revit-Toolkit/releases/tag/components-2026-10-05). При выборе источника **3 — GitHub Releases** скрипт скачает выбранный компонент, проверит его и откроет официальный установщик.

English: In Licensing repair, select **5 — Identity Manager** or **8 — Network License Manager**, then **3 — GitHub Releases**. Pinned versions: Identity **1.21.0.9** (official UCT installer), NLM **11.19.9.0**, FAB **1.9**. Missing FAB is offered for download and portable extraction. All packages require the pinned SHA256; Autodesk installers additionally require a valid Autodesk signature. Dry run performs no downloads or installation. **All three packages are published in [GitHub Releases](https://github.com/viendhyra/Revit-Toolkit/releases/tag/components-2026-10-05).** Select source 3 to download, verify and open the component installer.

Подготовка публикации описана в [RELEASE-COMPONENTS.md](RELEASE-COMPONENTS.md). Проверки загрузчика без сети и установки:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Test-Components.ps1
```

| Параметр | Назначение |
|---|---|
| `-Module <ключ>` | Запуск одного модуля, без главного меню |
| `-Language ru / en` | Язык текущего запуска без вопроса; сохранённый выбор не меняется |
| `-DryRun` | Сухой прогон: поиск и план выводятся, изменения не выполняются |
| `-Yes` | Без подтверждений (автоматизация, использовать осознанно) |
| `-NoColor` | Отключить ANSI-цвета |
| `-Ascii` | ASCII вместо псевдографики (старые консоли, шрифты без глифов) |
| `-NoAnimation` | Отключить заставку и анимацию появления меню |

## Терминальный интерфейс

При первом интерактивном запуске выберите **1 — Русский** или **2 — English**. Выбор сохраняется в `%LOCALAPPDATA%\RevitToolkit\language.txt` и применяется при следующих запусках, включая обновление скрипта из GitHub. Меню, подсказки, подтверждения и сообщения модулей доступны на двух языках. Сообщения ошибок Windows и названия найденных файлов остаются в исходном виде.

Сменить язык: **9 — Настройки сессии → 4 — Язык интерфейса**. Для автоматизации или отдельного запуска используйте `-Language en` / `-Language ru`. При перенаправленном вводе и отсутствии сохранённого выбора используется русский язык без вопроса.

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\RevitToolkit.ps1 -Language en
```

В команде запуска из GitHub также можно добавить `-Language en` после `-File $toolkitScript`. Проверка переводов и сохранения выбора: `powershell.exe -NoProfile -File .\Test-Localization.ps1`.

Версия 1.1: стиль BIM-консоли, крупный текстовый логотип **R/T** в рамке, бирюзовый и синий акценты, выделенный пункт, описание текущего действия, статусы LIVE/DRY RUN, ADMIN/USER и RU/EN. Крупный логотип отображается в окне шириной от 70 и высотой от 30 символов; в маленьких окнах — компактная шапка. Меню прокручивается под доступную высоту терминала. Стрелки, Home/End, Enter и клавиши пунктов; Escape/Q — назад. Прогресс обновляется на месте.

В интерактивной консоли с ANSI — световой проход по логотипу (около 0,36 секунды) и последовательное появление пунктов. Нажатие клавиши завершает заставку, сохраняя ввод для меню. Для анимации крупного логотипа увеличьте окно терминала до указанных размеров. `-NoAnimation` убирает задержки; `-Ascii` и `-NoColor` также отключают анимацию. ASCII-режим использует логотип и рамку из обычных символов. При перенаправлении вывода анимация и ANSI отключены. В консолях без чтения клавиш остаётся ввод через `Read-Host`.

Проверка интерфейса без операций обслуживания: `powershell.exe -NoProfile -File .\Test-TerminalUi.ps1`.

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
